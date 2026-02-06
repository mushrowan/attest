# nixos-test-ng: elixir-based nixos test driver

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
│                  (NixosTest.Application)                        │
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
    ├── Backend.QEMU      — Port.open, QMP, virtconsole shell
    ├── Backend.Mock      — injected pids for unit tests
    └── (future)
        ├── Backend.Firecracker   — REST API, vsock shell
        └── Backend.CloudHypervisor — REST API, virtconsole

Shell GenServer (command protocol)
└── delegates connection to Transport behaviour
    ├── Transport.VirtConsole — listen/accept on unix socket
    └── (future)
        └── Transport.Vsock   — firecracker vsock
```

## file structure

```
lib/nixos_test/
├── application.ex                   # OTP app, supervisors
├── cli.ex                           # escript CLI (eval, eval-file)
├── driver.ex                        # test coordinator GenServer
├── machine.ex                       # VM GenServer, delegates to backend
└── machine/
    ├── backend.ex                   # @behaviour
    ├── backend/
    │   ├── qemu.ex                  # QEMU: Port.open, QMP, shell
    │   └── mock.ex                  # unit test mock
    ├── qmp.ex                       # QMP protocol client GenServer
    ├── shell.ex                     # command protocol GenServer
    └── shell/
        ├── transport.ex             # @behaviour
        └── transport/
            └── virtconsole.ex       # unix socket listen/accept
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

- `init/1`, `start/1` — lifecycle
- `shutdown/2`, `halt/2`, `wait_for_shutdown/2` — teardown
- `cleanup/1` — resource cleanup
- `screenshot/2`, `send_key/2` — optional capabilities
- `handle_port_exit/2` — port exit notification
- `capabilities/1` — introspection

### Backend.QEMU

extracts all QEMU-specific code from the old machine.ex:
- spawns QEMU via `Port.open`
- creates Shell listener, waits for virtconsole connection
- connects QMP with retry logic
- halt sends QMP `quit`, shutdown sends `poweroff` via shell

### Backend.Mock

wraps injected QMP and Shell pids for unit testing. all lifecycle
operations are no-ops. screenshot delegates to QMP if available.

### Shell (GenServer)

transport-agnostic command protocol. delegates connection to a
Transport implementation, then sends/receives using the base64
protocol:

1. send: `bash -c '<command>' | (base64 -w 0; echo)\n`
2. recv: `<base64 output>\n`
3. send: `echo ${PIPESTATUS[0]}\n`
4. recv: `<exit code>\n`

### Transport.VirtConsole

listens on a unix socket, accepts guest connection, waits for
"Spawning backdoor root shell..." ready message. used by QEMU
and cloud-hypervisor backends.

### QMP (GenServer)

QEMU Machine Protocol client. JSON over unix socket. handles
greeting/capability negotiation, skips async events when waiting
for command responses.

### Driver (GenServer)

coordinates test execution. creates machines via MachineSupervisor,
provides `start_all/1` for parallel boot, `get_machine/2` for
lookup. handles global timeout.

## future work

- `Backend.Firecracker` — REST API, vsock shell, snapshot/restore
- `Transport.Vsock` — firecracker vsock UDS + CONNECT protocol
- `Network` behaviour — bridge-based networking (replaces VDE)
- snapshot/restore for "boot once, fork many" test execution
- in-guest screenshots via xvfb + imagemagick (non-QEMU backends)
- test DSL / nix integration
