# progress log

## 2026-01-31: Machine.start connects to QMP

### done
- **Machine.start/1** connects to QMP socket via `qmp_socket_path` option
- added `connect_qmp/2` helper, starts QMP GenServer and stores in state
- handles three start cases: no-op, QMP-only, and full (spawn + QMP)
- 37 tests total, all passing

### next steps
1. Machine.start waits for shell connection
2. add retry logic for QMP connection (socket may not exist immediately)
3. add integration tests with real QEMU

---

## 2026-01-31: earlier (condensed)

- Machine.start/1 executes start_command via Port.open, handles exit status
- Driver.start_all/1 calls Machine.start in parallel, Machine.booted?/1 added
- Driver.init accepts machines config, creates Machines under MachineSupervisor
- Machine delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit, wait_for_open_port
- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- project setup: flake-parts, elixir 1.17, treefmt
