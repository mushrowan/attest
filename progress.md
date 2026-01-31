# progress log

## 2026-01-31: integrate QMP + Shell into Machine

### done
- **Machine GenServer** now delegates to QMP/Shell:
  - execute/2 → Shell.execute (returns `{exit_code, output}`)
  - screenshot/2 → QMP.command("screendump", ...)
  - stop/1 → QMP.command("quit")
  - wait_for_unit/3 → polls systemctl until active/failed
  - wait_for_open_port/3 → polls nc -z until port open
- accepts injected QMP/Shell pids for testing
- crashes with descriptive errors when not connected
- 32 tests total, all passing

### next steps
1. implement actual VM lifecycle (start QEMU process)
2. implement Driver test coordination
3. add integration tests with real QEMU

---

## 2026-01-31: earlier (condensed)

- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- fix flake test check: added mixFodDepsAll
- project setup: flake-parts, elixir 1.17
