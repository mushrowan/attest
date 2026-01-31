# progress log

## 2026-01-31: Driver creates machines from config

### done
- **Driver.init** now accepts `machines: [%{name: "client", ...}]` option
- creates Machine GenServers under MachineSupervisor (not linked to Driver)
- `get_machine/2` returns `{:ok, pid}` for machines created from config
- 33 tests total, all passing

### next steps
1. implement actual VM lifecycle (start QEMU process)
2. make `start_all/1` call Machine.start on each machine
3. add integration tests with real QEMU

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
