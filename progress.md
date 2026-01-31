# progress log

## 2026-01-31: Driver cleanup test

### done
- added test verifying machines are stopped when Driver terminates
- 35 tests total, all passing

### next steps
1. implement actual VM lifecycle (start QEMU process)
2. add integration tests with real QEMU

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
