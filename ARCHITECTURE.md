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
| hot code reload | built-in (useful for interactive mode) |

## architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Supervisor                        │
│                     (NixosTest.Application)                         │
└─────────────────────────────────────────────────────────────────────┘
                                  │
          ┌───────────────────────┼───────────────────────┐
          ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Driver         │     │  VLan.Supervisor │     │  Logger         │
│  (GenServer)    │     │  (DynamicSup)   │     │  (GenServer)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
          │                       │
          │               ┌───────┴───────┐
          │               ▼               ▼
          │       ┌─────────────┐ ┌─────────────┐
          │       │ VLan 1      │ │ VLan 2      │
          │       │ (GenServer) │ │ (GenServer) │
          │       └─────────────┘ └─────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Machine.Supervisor                              │
│                      (DynamicSupervisor)                            │
└─────────────────────────────────────────────────────────────────────┘
          │
          ├─────────────────┬─────────────────┬─────────────────┐
          ▼                 ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Machine "web"   │ │ Machine "db"    │ │ Machine "client"│
│ (GenServer)     │ │ (GenServer)     │ │ (GenServer)     │
│                 │ │                 │ │                 │
│ ┌─────────────┐ │ │ ┌─────────────┐ │ │ ┌─────────────┐ │
│ │ QMP Client  │ │ │ │ QMP Client  │ │ │ │ QMP Client  │ │
│ │ (GenServer) │ │ │ │ (GenServer) │ │ │ │ (GenServer) │ │
│ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────┘ │
│ ┌─────────────┐ │ │ ┌─────────────┐ │ │ ┌─────────────┐ │
│ │ Shell       │ │ │ │ Shell       │ │ │ │ Shell       │ │
│ │ (GenServer) │ │ │ │ (GenServer) │ │ │ │ (GenServer) │ │
│ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────┘ │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

## module breakdown

### NixosTest.Application
- OTP application entry point
- starts top-level supervisor
- configures logging

### NixosTest.Driver (GenServer)
- main coordinator
- loads test configuration
- spawns machines via Machine.Supervisor
- executes test script
- handles global timeout
- exposes API for test scripts

```elixir
# state
%Driver{
  machines: %{name => pid},
  vlans: %{nr => pid},
  test_script: fun(),
  out_dir: Path.t(),
  global_timeout: integer()
}
```

### NixosTest.Machine (GenServer)
- represents one QEMU VM
- manages VM lifecycle (boot, shutdown, reboot)
- owns QMP and Shell child processes
- provides test API: succeed/1, fail/1, wait_for_unit/2, etc

```elixir
# state
%Machine{
  name: String.t(),
  start_command: String.t(),
  qmp: pid(),           # QMP client process
  shell: pid(),         # shell backdoor process
  qemu: port(),         # QEMU OS process
  booted: boolean(),
  connected: boolean(),
  state_dir: Path.t(),
  shared_dir: Path.t()
}

# key callbacks
handle_call(:start, ...)        -> boots QEMU, connects shell
handle_call({:execute, cmd}, ...)  -> runs command via shell
handle_call(:screenshot, ...)   -> captures via QMP
handle_info({:EXIT, qemu, _}, ...)  -> handles VM crash
```

### NixosTest.Machine.QMP (GenServer)
- QEMU Machine Protocol client
- JSON over unix socket
- handles async events (STOP, RESUME, SHUTDOWN)
- provides: screenshot, sendkey, quit, device_add, etc

```elixir
# state
%QMP{
  socket: :gen_tcp.socket(),
  pending: %{id => from},  # pending requests
  events: [event()]        # queued events
}

# protocol
send: {"execute": "screendump", "arguments": {"filename": "/tmp/shot.ppm"}}
recv: {"return": {}}
recv: {"event": "STOP", "timestamp": ...}
```

### NixosTest.Machine.Shell (GenServer)
- virtconsole shell backdoor
- executes commands inside guest
- handles output streaming
- protocol: send command, read until magic delimiter

```elixir
# protocol (same as python driver)
send: "( <command> ); echo '|!=EOF' $?\n"
recv: <output...> |!=EOF 0\n
parse: {output, exit_code}
```

### NixosTest.VLan (GenServer)
- manages vde_switch process
- provides socket path for VMs to connect
- handles cleanup on termination

```elixir
%VLan{
  nr: integer(),
  switch: port(),        # vde_switch OS process
  socket_dir: Path.t()
}
```

### NixosTest.Logger (GenServer)
- structured logging with nesting
- outputs: terminal (coloured), XML, JUnit XML
- handles per-machine log prefixing

```elixir
# API
Logger.nested("booting machines", fn ->
  Logger.log("starting web")
  ...
end)

Logger.log_serial("web", "[  OK  ] Started nginx")
```

## test DSL

tests would be written in elixir (or a small DSL that compiles to elixir):

```elixir
# option 1: native elixir
defmodule MyTest do
  use NixosTest

  test "nginx serves content" do
    start_all()
    
    machine("web") |> wait_for_unit("nginx.service")
    machine("client") |> succeed("curl http://web")
  end
end

# option 2: lightweight DSL (embedded in nix)
testScript = ''
  start_all!
  
  web |> wait_for_unit "nginx.service"
  client |> succeed "curl http://web"
'';

# option 3: data-driven (for simpler tests)
testScript = {
  steps = [
    { action = "start_all"; }
    { action = "wait_for_unit"; machine = "web"; unit = "nginx.service"; }
    { action = "succeed"; machine = "client"; command = "curl http://web"; }
  ];
};
```

## key advantages over python

### 1. supervision & fault tolerance
```elixir
# if a VM crashes unexpectedly, supervisor can:
# - restart it (with backoff)
# - notify the driver
# - collect crash info
# python just... crashes
```

### 2. true concurrency
```elixir
# boot all VMs in parallel, properly
Task.async_stream(machines, &Machine.start/1)
|> Enum.to_list()

# python uses threading with GIL limitations
```

### 3. pattern matching for protocol handling
```elixir
def handle_qmp_message(%{"event" => "SHUTDOWN"}, state) do
  {:noreply, %{state | shutting_down: true}}
end

def handle_qmp_message(%{"return" => result, "id" => id}, state) do
  GenServer.reply(state.pending[id], {:ok, result})
  {:noreply, %{state | pending: Map.delete(state.pending, id)}}
end

def handle_qmp_message(%{"error" => err}, state) do
  {:stop, {:qmp_error, err}, state}
end
```

### 4. timeouts are first-class
```elixir
def wait_for_unit(machine, unit, timeout \\ 900_000) do
  GenServer.call(machine, {:wait_for_unit, unit}, timeout)
end
# automatic timeout handling, no manual threading
```

### 5. interactive mode via IEx
```elixir
# drop into IEx with full access to running VMs
iex> web |> succeed("systemctl status nginx")
iex> web |> screenshot("debug.png")
iex> Process.info(web)  # inspect GenServer state
```

## file structure

```
nixos-test-ng/
├── mix.exs
├── lib/
│   ├── nixos_test.ex                 # main API
│   ├── nixos_test/
│   │   ├── application.ex            # OTP app
│   │   ├── driver.ex                 # coordinator
│   │   ├── machine.ex                # VM genserver
│   │   ├── machine/
│   │   │   ├── qmp.ex                # QMP client
│   │   │   ├── shell.ex              # shell backdoor
│   │   │   └── start_command.ex      # QEMU command builder
│   │   ├── vlan.ex                   # VDE switch
│   │   ├── logger.ex                 # structured logging
│   │   └── dsl.ex                    # test DSL macros
│   └── mix/
│       └── tasks/
│           └── nixos_test.ex         # mix nixos.test task
├── test/
│   └── nixos_test_test.exs
└── nix/
    ├── default.nix                   # package definition
    ├── module.nix                    # nixos test module integration
    └── flake.nix                     # flake wrapper
```

## nix integration

the driver would be packaged for nix and integrate with the existing test infrastructure:

```nix
# nix/module.nix - drop-in replacement for testing-python.nix
{ config, lib, pkgs, ... }:

{
  options.test = {
    driver = lib.mkOption {
      type = lib.types.enum [ "python" "elixir" ];
      default = "python";
      description = "which test driver to use";
    };
  };

  config = lib.mkIf (config.test.driver == "elixir") {
    # use elixir driver instead
    test.driverPackage = pkgs.nixos-test-ng;
  };
}
```

## migration path

1. **phase 1**: implement core driver, run alongside python
2. **phase 2**: compatibility layer for existing python test scripts
3. **phase 3**: new tests written in elixir DSL
4. **phase 4**: gradually migrate existing tests
5. **phase 5**: deprecate python driver

## open questions

- **test script format**: native elixir, custom DSL, or data-driven?
- **backwards compat**: transpile python test scripts to elixir?
- **OCR support**: port tesseract integration or shell out?
- **remote debugging**: equivalent to python's remote_pdb?
- **nix integration**: how to pass test script from nix to elixir?

## estimated effort

| component | complexity | lines (est) |
|-----------|------------|-------------|
| application/supervisor | low | ~50 |
| driver | medium | ~200 |
| machine | high | ~400 |
| qmp client | medium | ~150 |
| shell client | medium | ~100 |
| vlan | low | ~80 |
| logger | medium | ~150 |
| test DSL | medium | ~200 |
| CLI | low | ~100 |
| nix integration | medium | ~100 |
| **total** | | **~1500** |

comparable to the python driver (~1500 lines), but with better structure.
