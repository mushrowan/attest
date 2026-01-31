# progress log

## 2026-01-31: graceful shutdown

### done
- `Machine.shutdown/2`: graceful shutdown via guest `poweroff` command, waits for exit
- `Machine.halt/2`: immediate stop via QMP `quit`, waits for exit
- `Machine.wait_for_shutdown/2`: wait for QEMU process to exit
- Shell.execute now returns `{:error, reason}` instead of crashing on socket errors
- integration test uses graceful shutdown
- 43 unit tests passing

### next steps
1. add more integration tests (screenshot, multi-vm)
2. consider adding reboot support

---

## 2026-01-31: earlier (condensed)

- integration tests with real QEMU VM (boot -> execute -> wait_for_unit -> shutdown)
- CLI: `eval` and `eval-file` subcommands
- QMP: skip async events, retry connection 10x
- Machine.start/1 handles spawn/QMP/shell combinations
- Machine delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit
- Driver: start_all/1, get_machine/2, manages MachineSupervisor
