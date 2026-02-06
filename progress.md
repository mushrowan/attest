# progress log

## 2026-02-06: hypervisor abstraction plan

### context

researched firecracker, cloud-hypervisor, microvm.nix as alternative VM backends.
firecracker IS viable (previously dismissed) — vsock replaces virtconsole for shell
backdoor, snapshot/restore enables "boot once, fork many" (~100ms restore vs ~5s boot),
linux bridges replace VDE. cloud-hypervisor also viable (has virtconsole natively).
GUI testing without VGA works via xvfb + xdotool inside guest.

### decisions

1. **backend owns full boot sequence** — Machine delegates to backend, backend handles
   process spawning, control plane connection, shell setup, everything backend-specific
2. **mock backend for tests** — no dual code paths; Machine always goes through backend
   interface. `Backend.Mock` wraps injected qmp/shell pids. existing tests get mechanical
   `backend: Backend.Mock` addition (~1 line each)
3. **optional capabilities return `{:error, :unsupported}`** — screenshot, send_key, etc.
   callers decide what to do

### plan

see PLAN.md for full implementation plan

---

## 2026-01-31: multi-vm debugging (in progress)

### problem identified
Multi-VM integration test failing - VMs timeout waiting for shell connection

### root cause found
1. **env var syntax**: `VAR=value cmd` doesn't work with `Port.open({:spawn, ...})` - needs `env VAR=value cmd`
2. **socket timing**: QEMU connects to shell socket immediately on start, but we were creating the socket AFTER spawning QEMU

### fixes applied
- Shell.wait_for_connection now properly uses timeout parameter (was hardcoded 30s)
- Multi-vm test uses `env` command for environment variables
- Machine.start reordered: create shell socket FIRST, then spawn QEMU, then wait for connection

### still needs testing
- multi-vm test not yet verified working after fixes
- code has unused functions (connect_shell, flush_port_messages) to clean up

### files modified
- `lib/nixos_test/machine.ex` - reordered start sequence
- `lib/nixos_test/machine/shell.ex` - timeout parameter fix  
- `integration-tests/multi-vm-test.exs` - env command, debug output

---

## 2026-01-31: graceful shutdown (done)

- `Machine.shutdown/2`, `Machine.halt/2`, `Machine.wait_for_shutdown/2`
- Shell.execute returns `{:error, reason}` on socket errors
- 43 unit tests passing, single-vm integration test passing

---

## 2026-01-31: earlier (condensed)

- integration tests with real QEMU VM (boot -> execute -> wait_for_unit -> shutdown)
- CLI: `eval` and `eval-file` subcommands
- QMP: skip async events, retry connection 10x
- Machine.start/1 handles spawn/QMP/shell combinations
- Machine delegates to QMP/Shell for execute, screenshot, stop, wait_for_unit
- Driver: start_all/1, get_machine/2, manages MachineSupervisor
