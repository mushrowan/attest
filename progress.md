# progress log

## 2026-01-31: integration tests with real QEMU

### done
- `integration-tests/` directory with vm.nix, run-test.exs, default.nix
- vm.nix: minimal NixOS VM with test-instrumentation (backdoor service)
- run-test.exs: full lifecycle test (boot -> execute -> wait_for_unit -> stop)
- CLI: added `eval` and `eval-file` subcommands
- QMP: skip events when waiting for command responses
- `nix flake check` passes including integration test (~10s on KVM)

### next steps
1. implement Machine.shutdown gracefully (wait for process exit)
2. add more integration tests (screenshot, multi-vm)

---

## 2026-01-31: earlier (condensed)

- QMP retry logic: `connect_qmp/3` retries 10x with 100ms delay
- Machine.start/1 waits for shell connection, handles spawn/QMP/shell combos
- Machine delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit
- Machine.QMP: parse/encode messages, connect + negotiate, command/3
- Machine.Shell: format/parse commands, listen socket, execute/2
- Driver: start_all/1, get_machine/2, manages MachineSupervisor
- 39 unit tests passing
