# progress log

## 2026-01-31: QMP retry logic

### done
- `connect_qmp/3` retries up to 10 times with 100ms delay when socket not ready
- checks `File.exists?` before attempting connection to avoid EXIT signals
- 39 tests total, all passing

### next steps
1. add integration tests with real QEMU
2. implement Machine.shutdown gracefully

---

## 2026-01-31: earlier (condensed)

- Machine.start/1 waits for shell connection via `shell_socket_path` option
- unified start handler handles spawn/QMP/shell combinations

---

## 2026-01-31: earlier (condensed)

- Machine.start/1 executes start_command via Port.open, handles exit status
- Driver.start_all/1 calls Machine.start in parallel, Machine.booted?/1 added
- Driver.init accepts machines config, creates Machines under MachineSupervisor
- Machine delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit, wait_for_open_port
- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- project setup: flake-parts, elixir 1.17, treefmt
