# progress log

## 2026-01-31: Machine.start executes start_command

### done
- **Machine.start/1** now executes `start_command` via `Port.open`
- handles port exit status and output messages
- robust terminate (handles already-closed ports)
- Driver.terminate checks Process.alive? before stopping machines
- 36 tests total, all passing

### next steps
1. Machine.start connects to QMP socket after spawning
2. Machine.start waits for shell connection
3. add integration tests with real QEMU

---

## 2026-01-31: earlier (condensed)

- Driver.start_all/1 calls Machine.start in parallel, Machine.booted?/1 added
- Driver.init accepts machines config, creates Machines under MachineSupervisor
- Machine delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit, wait_for_open_port
- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- project setup: flake-parts, elixir 1.17, treefmt

---

## 2026-01-31: earlier (condensed)

- Machine GenServer delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit, wait_for_open_port
- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- project setup: flake-parts, elixir 1.17, treefmt

---

## 2026-01-31: earlier (condensed)

- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- fix flake test check: added mixFodDepsAll
- project setup: flake-parts, elixir 1.17
