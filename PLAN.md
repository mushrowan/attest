# hypervisor abstraction plan

## goal

decouple Machine from QEMU so we can support multiple VM backends (QEMU, firecracker,
cloud-hypervisor) without changing the test-facing API

## current architecture (QEMU-coupled)

```
Machine GenServer
├── spawns QEMU via Port.open
├── connects QMP (unix socket, JSON protocol)
├── creates Shell listener (unix socket, virtconsole)
├── screenshots via QMP screendump
└── halt via QMP quit
```

three QEMU-specific concerns tangled in machine.ex:
1. process management (Port.open)
2. control plane (QMP)
3. shell transport (virtconsole unix socket)

## target architecture

```
Machine GenServer (public API unchanged)
└── delegates to Backend behaviour
    ├── Backend.QEMU     — Port.open, QMP, virtconsole shell
    ├── Backend.Mock      — injected pids for unit tests
    └── (future)
        ├── Backend.Firecracker  — REST API, vsock shell, snapshot/restore
        └── Backend.CloudHypervisor — REST API, virtconsole shell

Shell GenServer (command protocol unchanged)
└── delegates connection to Transport behaviour
    ├── Transport.VirtConsole  — listen/accept on unix socket (QEMU, cloud-hypervisor)
    └── (future)
        └── Transport.Vsock    — connect to firecracker vsock UDS + CONNECT protocol
```

## file structure after refactor

```
lib/nixos_test/
├── machine.ex                      # GenServer, delegates to backend
├── machine/
│   ├── backend.ex                  # @behaviour
│   ├── backend/
│   │   ├── qemu.ex                 # extract from current machine.ex
│   │   └── mock.ex                 # for unit tests
│   ├── shell.ex                    # command protocol (transport-agnostic)
│   ├── shell/
│   │   ├── transport.ex            # @behaviour
│   │   └── transport/
│   │       └── virtconsole.ex      # extract from current shell.ex
│   └── qmp.ex                      # stays as-is (QEMU-specific)
```

## behaviours

### Machine.Backend

```elixir
defmodule NixosTest.Machine.Backend do
  @type config :: map()
  @type state :: term()

  # lifecycle
  @callback init(config) :: {:ok, state}
  @callback start(state) :: {:ok, shell_pid :: pid(), state} | {:error, term()}
  @callback shutdown(state, timeout()) :: :ok | {:error, term()}
  @callback halt(state, timeout()) :: :ok | {:error, term()}
  @callback wait_for_shutdown(state, timeout()) :: :ok | {:error, :timeout}
  @callback cleanup(state) :: :ok

  # optional capabilities — return {:error, :unsupported} if not available
  @callback screenshot(state, filename :: String.t()) :: :ok | {:error, term()}
  @callback send_key(state, key :: String.t()) :: :ok | {:error, term()}

  # introspection
  @callback capabilities() :: [:screenshot | :send_key | :network_control]
end
```

### Shell.Transport

```elixir
defmodule NixosTest.Machine.Shell.Transport do
  @type config :: map()

  # returns a connected socket ready for the shell command protocol
  @callback connect(config, timeout()) :: {:ok, :gen_tcp.socket()} | {:error, term()}

  # cleanup
  @callback close(:gen_tcp.socket()) :: :ok
end
```

## machine struct (after refactor)

```elixir
defstruct [
  :name,
  :shell,           # Shell GenServer pid (set by backend on start)
  :booted,
  :connected,
  :backend_mod,     # e.g. Backend.QEMU
  :backend_state,   # opaque, managed by backend
  :callbacks
]
```

## implementation phases

### phase 1: fix existing bugs (TDD, ~30 min)

1. RED: verify `handle_call(:booted?, ...)` is missing — 4 tests fail
2. GREEN: add the clause
3. REFACTOR: remove unused `connect_shell/3`, `flush_port_messages/1`
4. `mix test` → 43/43, `nix flake check --quiet`

### phase 2: Machine.Backend behaviour (~1-2 hr)

#### 2a: write the behaviour

- `lib/nixos_test/machine/backend.ex` — behaviour + typespecs
- test: module compiles, behaviour_info works

#### 2b: write Backend.QEMU

extract from machine.ex:
- `init/1`: stores start_command, socket paths, state_dir, shared_dir
- `start/1`: creates shell listener → spawns QEMU port → waits for shell → connects QMP
- `shutdown/2`: sends `poweroff` via shell, waits for process exit
- `halt/2`: sends QMP `quit`, waits for process exit
- `wait_for_shutdown/2`: waits for port exit_status
- `cleanup/1`: stops QMP/Shell GenServers, closes port
- `screenshot/2`: QMP screendump command
- `send_key/2`: QMP sendkey command (not yet implemented, stub with :unsupported)
- `capabilities/0`: `[:screenshot]`

handle_info for port messages moves here too (or stays in Machine, forwarding to backend)

#### 2c: write Backend.Mock

- `init/1`: stores injected `:qmp` and `:shell` pids
- `start/1`: returns the injected shell pid, no-op otherwise
- `shutdown/2`, `halt/2`: no-op, return `:ok`
- `screenshot/2`: delegates to injected QMP if present, else `{:error, :unsupported}`
- `capabilities/0`: `[:screenshot]` if qmp injected, else `[]`

#### 2d: refactor Machine GenServer

- remove all QEMU-specific code (Port.open, QMP connect, socket paths)
- `init/1`: calls `backend_mod.init(config)`, stores backend_mod + backend_state
- `handle_call(:start, ...)`: calls `backend_mod.start(backend_state)`, gets shell pid
- `handle_call({:screenshot, ...})`: calls `backend_mod.screenshot(backend_state, filename)`
- `handle_call({:shutdown, ...})`: calls `backend_mod.shutdown(backend_state, timeout)`
- `handle_call({:halt, ...})`: calls `backend_mod.halt(backend_state, timeout)`
- keep shell-based operations (execute, wait_for_unit, wait_for_open_port) in Machine

#### 2e: update tests

mechanical changes to existing Machine tests:
```elixir
# before
Machine.start_link(name: "test", qmp: mock_qmp, shell: mock_shell)

# after
Machine.start_link(name: "test", backend: Backend.Mock, qmp: mock_qmp, shell: mock_shell)
```

write new Backend.QEMU-specific tests (QMP connection, screenshot, halt via QMP)

#### 2f: verify

`mix test` → all pass, `nix flake check --quiet`

### phase 3: Shell.Transport behaviour (~45 min)

#### 3a: write the behaviour

- `lib/nixos_test/machine/shell/transport.ex`

#### 3b: extract Transport.VirtConsole

from current shell.ex:
- `connect/2`: rm socket, listen, accept, wait_for_backdoor_ready → return connected socket
- `close/1`: close socket + listen socket

#### 3c: refactor Shell

- `init/1`: accepts `transport` option (default: VirtConsole)
- connection logic delegates to transport
- command protocol (format_command, parse_output, do_execute) unchanged

#### 3d: verify

shell tests stay unchanged (mock at socket level, below transport)
`mix test` → all pass, `nix flake check --quiet`

### phase 4: docs

- update ARCHITECTURE.md with new diagrams
- update progress.md

## future work (not in this plan)

- `Backend.Firecracker` — REST API, vsock shell, snapshot/restore
- `Transport.Vsock` — connect to firecracker vsock UDS
- `Network` behaviour — bridge-based networking (replaces VLan/VDE)
- `Backend.CloudHypervisor` — REST API, virtconsole shell
- in-guest screenshots via xvfb + imagemagick (for non-QEMU backends)
- in-guest keyboard via xdotool (for non-QEMU backends)
- snapshot/restore for "boot once, fork many" test execution

## research notes

### firecracker viability

- **vsock replaces virtconsole**: host connects to firecracker UDS, sends `CONNECT <port>\n`,
  gets bidirectional stream to guest. guest runs socat/custom daemon on AF_VSOCK. same
  command protocol, only connection establishment changes. kata containers uses this pattern
- **snapshot/restore**: boot once, snapshot after systemd ready, restore in ~50-150ms per clone.
  memory is MAP_PRIVATE mmap (CoW). disk CoW via reflink/dm-snapshot. this is how AWS Lambda works
- **networking**: TAP + linux bridges replace VDE. `ip link set down` replaces `set_link`.
  `tc`/`netem` adds packet loss/latency/corruption (more capable than QEMU)
- **GUI**: xvfb + xdotool inside guest. screenshots via `import -display :99` transferred over
  shell/vsock. no pre-boot screen capture, but irrelevant for 99%+ of NixOS tests
- **no virtconsole, no QMP, no VGA** — all replaced by the above

### cloud-hypervisor viability

- has virtconsole (shell backdoor works unchanged)
- has virtiofs (shared dirs)
- REST API instead of QMP
- no VGA/screenshots, no keyboard sim
- less compelling than firecracker since no snapshot/restore perf story

### ~80%+ of nixpkgs NixOS tests are shell-only

tests using only succeed/fail/wait_for_unit/wait_for_open_port don't need VGA, keyboard,
or any QEMU-specific features. these can run on any backend
