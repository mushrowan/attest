# attest: elixir-based nixos test driver

## why elixir?

elixir/OTP is almost purpose-built for this problem:

| requirement | OTP feature |
|-------------|-------------|
| manage N concurrent VMs | supervision trees |
| VM lifecycle (start/stop/crash) | GenServer + supervisors |
| react to VM events | message passing |
| timeout handling | built-in GenServer timeouts |
| parallel test execution | Task.async_stream |
| fault tolerance | "let it crash" philosophy |

## architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Application Supervisor                        │
│                  (Attest.Application)                        │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼──────────────────┐
          ▼                   ▼                  ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────┐
│ Driver           │ │ MachineRegistry  │ │ MachineSup   │
│ (GenServer)      │ │ (Registry)       │ │ (DynSup)     │
└──────────────────┘ └──────────────────┘ └──────────────┘
          │                                      │
          ▼                                      │
    start_all/1                         ┌────────┼────────┐
    get_machine/2                       ▼        ▼        ▼
                                   Machine   Machine   Machine
                                   "web"     "db"      "client"
```

## machine + backend architecture

```
Machine GenServer (public API)
├── execute, wait_for_unit, wait_for_open_port (shell-based)
├── start, shutdown, halt, screenshot (delegated to backend)
└── delegates to Backend behaviour
    ├── Backend.QEMU            -- Port.open, QMP, virtconsole shell
    ├── Backend.Firecracker     -- REST API, vsock shell, TAP networking
    ├── Backend.CloudHypervisor -- REST API, vsock shell, TAP networking
    ├── Backend.SSH             -- SSH shell, no hypervisor
    ├── Backend.Nspawn          -- systemd-nspawn container, no KVM
    └── Backend.Mock            -- injected pids for unit tests

Shell GenServer (command protocol)
└── delegates connection to Transport behaviour
    ├── Transport.VirtConsole -- listen/accept on unix socket
    ├── Transport.Vsock       -- firecracker vsock CONNECT protocol
    └── Transport.SSH         -- SSH channel via bridge GenServer
```

## file structure

```
lib/
├── attest.ex                        # public API (succeed, fail, wait_for_unit, etc.)
└── attest/
    ├── application.ex               # OTP app, supervisors
    ├── cli.ex                       # escript CLI (eval, eval-file)
    ├── driver.ex                    # test coordinator GenServer
    ├── dsl.ex                       # test script helpers (subtest, retry, assertions)
    ├── machine.ex                   # VM GenServer, delegates to backend
    ├── machine_config.ex            # JSON config parser
    ├── start_command.ex             # legacy start script builder
    ├── test_script.ex               # test script evaluator
    ├── vlan.ex                      # VDE switch manager
    └── machine/
        ├── backend.ex               # @behaviour (14 callbacks)
        ├── backend/
        │   ├── api.ex               # HTTP/1.1 client over UDS (shared)
        │   ├── micro_vm.ex          # shared microVM macro (vsock, TAP, stubs)
        │   ├── qemu.ex              # QEMU: Port.open, QMP, shell
        │   ├── firecracker.ex       # firecracker: REST API, vsock, snapshots
        │   ├── cloud_hypervisor.ex  # cloud-hypervisor: REST API, vsock, snapshots
        │   ├── ssh.ex               # SSH: remote host, no hypervisor
        │   ├── nspawn.ex            # systemd-nspawn: container, no KVM
        │   └── mock.ex              # unit test mock
        ├── guest_screenshot.ex      # in-guest screenshot capture (fbgrab/X11)
        ├── keyboard.ex              # key name mapping
        ├── ocr.ex                   # OCR via tesseract
        ├── qmp.ex                   # QMP protocol client GenServer
        ├── shell.ex                 # command protocol GenServer
        └── shell/
            ├── transport.ex         # @behaviour (connect, send, recv, close)
            └── transport/
                ├── virtconsole.ex   # unix socket listen/accept
                ├── vsock.ex         # firecracker vsock CONNECT
                └── ssh.ex           # SSH channel + bridge GenServer
```

## module details

### Machine (GenServer)

the public API for interacting with VMs. keeps shell-based operations
(execute, wait_for_unit, wait_for_open_port) and delegates everything
backend-specific through the Backend behaviour.

```elixir
%Machine{
  name: String.t(),
  shell: pid(),            # Shell GenServer pid (from backend)
  backend_mod: module(),   # e.g. Backend.QEMU
  backend_state: term(),   # opaque, managed by backend
  booted: boolean(),
  connected: boolean()
}
```

### Backend behaviour

each backend owns the full boot sequence: process spawning, control
plane connection, shell setup. callbacks:

- `init/1`, `start/1` -- lifecycle
- `shutdown/2`, `halt/2`, `wait_for_shutdown/2` -- teardown
- `cleanup/1` -- resource cleanup
- `screenshot/2`, `send_key/2` -- optional capabilities
- `handle_port_exit/2` -- port exit notification
- `capabilities/1` -- introspection

### Backend.QEMU

extracts all QEMU-specific code from the old machine.ex:
- spawns QEMU via `Port.open`
- creates Shell listener, waits for virtconsole connection
- connects QMP with retry logic
- halt sends QMP `quit`, shutdown sends `poweroff` via shell

### Backend.Firecracker

manages firecracker microVM lifecycle:
- spawns firecracker process, configures via REST API over UDS
- boots VM with `PUT /actions {"action_type": "InstanceStart"}`
- shell connected via vsock transport (CONNECT protocol)
- halt sends `SendCtrlAltDel` action, falls back to SIGTERM
- block/unblock via host-side `ip link set <tap> down/up`
- no VGA/QMP/SLIRP: screenshot, send_key, forward_port unsupported

uses `Firecracker.API` for HTTP/1.1 over UDS (hand-rolled, no deps).

### Backend.SSH

connects to already-running hosts over SSH. no hypervisor management:
- start opens SSH connection via Transport.SSH, returns shell pid
- shutdown sends `poweroff` over the shell, then cleans up
- halt just closes the SSH connection
- all optional capabilities unsupported (no VGA, snapshots, etc.)
- useful for cloud VMs, physical machines, or containers with sshd

### Backend.Nspawn

boots a NixOS system in a systemd-nspawn container. no KVM needed:
- start spawns nspawn with bind-mounted state dir, connects shell
  via VirtConsole transport (unix socket at /run/attest/shell.sock)
- shutdown sends `poweroff` over the shell
- halt calls `machinectl terminate`
- all optional capabilities unsupported (no VGA, snapshots, etc.)
- useful for CI, cheap VMs, and environments without nested virt

### Backend.Mock

wraps injected QMP and Shell pids for unit testing. all lifecycle
operations are no-ops. screenshot delegates to QMP if available.

### Shell (GenServer)

transport-agnostic command protocol. delegates connection to a
Transport implementation, then sends/receives using the base64
protocol. the Transport behaviour defines `connect/send/recv/close`
so Shell never calls `:gen_tcp` directly:

1. send: `bash -c '<command>' | (base64 -w 0; echo)\n`
2. recv: `<base64 output>\n`
3. send: `echo ${PIPESTATUS[0]}\n`
4. recv: `<exit code>\n`

### Transport.VirtConsole

listens on a unix socket, accepts guest connection, waits for
"Spawning backdoor root shell..." ready message. used by QEMU
and cloud-hypervisor backends.

### Transport.Vsock

connects to firecracker's vsock UDS, sends `CONNECT <port>\n`,
reads `OK <port>\n`, then waits for the shell backdoor ready message.
the resulting socket is in line mode, ready for the shell protocol.

### Transport.SSH

connects to a remote host over SSH (Erlang `:ssh` module), opens a
session channel, and requests a shell. a Bridge GenServer owns the
channel and provides synchronous send/recv by buffering `{:ssh_cm, ...}`
messages. supports password and key-based auth.

### QMP (GenServer)

QEMU Machine Protocol client. JSON over unix socket. handles
greeting/capability negotiation, skips async events when waiting
for command responses.

### Driver (GenServer)

coordinates test execution. creates machines via MachineSupervisor,
provides `start_all/1` for parallel boot, `get_machine/2` for
lookup. handles global timeout.

## networking

multi-VM tests use TAP devices on a linux bridge, created inside a
user+network namespace (no real root needed). the nix test runner:

1. calls `unshare --user --map-root-user --net` for a fresh namespace
2. creates a bridge per VLAN (`br{test}{vlan}`)
3. creates TAP devices per node per VLAN (`t{test}{node}{vlan}`)
4. attaches TAPs to bridges, brings everything up
5. runs the attest driver, which passes TAP names to firecracker via API

inside the guest, static IPs are assigned via test-instrumentation.nix:
`192.168.{vlan}.{nodeNumber}` where nodeNumber is alphabetical (1-indexed).
`/etc/hosts` is populated so nodes can reach each other by hostname.

requires `/dev/net/tun` in the nix sandbox:
```nix
nix.settings.extra-sandbox-paths = [ "/dev/net/tun" ];
```

QEMU tests use VDE switches (userspace) and don't need this.

## future work

### code quality
- run dialyzer and fix type warnings
- audit typespec coverage on all public functions

### advanced
- userfaultfd snapshot restore (external page fault handler for lazy memory loading)
- reflink/CoW rootfs copies in nix integration (near-instant vs full copy)
- nspawn nix integration (make-test.nix for containers, backdoor service)



## nix integration

```
nix/
├── driver.nix                # wraps escript with JSON config + test script
├── run.nix                   # executes driver in sandbox (+ network namespace)
├── make-test.nix             # QEMU: evaluates NixOS configs, builds VMs
├── firecracker/
│   ├── make-test.nix         # FC: evaluates configs, builds rootfs + vmlinux
│   ├── make-rootfs.nix       # full ext4 rootfs (~1.2GB)
│   ├── make-rootfs-minimal.nix  # mutable-only ext4 (~10MB) for split store
│   ├── make-store-image.nix  # compressed erofs /nix/store image
│   ├── test-instrumentation.nix  # vsock backdoor, static IPs, kernel modules
│   └── vsock-backdoor.nix    # systemd service for shell over vsock
├── cloud-hypervisor/
│   └── make-test.nix         # CH: reuses FC rootfs/store, PCI transport
└── bench.nix                 # backend comparison benchmark
```
