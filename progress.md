# progress log

## 2026-02-06: send_key, typespecs, credo, test fixes (done)

- `Machine.send_key/2` — splits key combos ("ctrl-alt-delete") into QKeyCode
  values for QMP `send-key` command. QEMU and Mock backends both support it
- typespecs added to all public functions across all modules. dialyzer clean
  (only expected IEx.start warning). fixed dialyzer warning in succeed/fail
  by adding `is_integer` guard to disambiguate tuples
- credo cleanup: flattened nested cases with `with`, fixed number formatting,
  alias ordering
- fixed flaky driver tests in nix sandbox: trap EXIT signals, use
  Process.monitor for cleanup assertions, catch :exit in driver terminate,
  ensure application started in test_helper

69 tests passing, `nix flake check` green.

---

## 2026-02-06: error handling (done)

Machine GenServer no longer crashes on errors — all handle_call paths
return `{:error, reason}` tuples instead of raising:
- `execute` on disconnected → `{:error, :not_connected}`
- `execute` shell errors → `{:error, reason}`
- `screenshot` errors → pass through from backend
- `wait_for_unit` failed → `{:error, {:unit_failed, unit}}`
- `wait_for_unit` timeout → `{:error, {:unit_timeout, unit, last_state}}`
- `wait_for_open_port` → `{:error, {:port_not_open, port}}`
- shell errors during polling → `{:error, {:shell_error, reason}}`

poll retry count now derived from timeout param (1 retry per second)
instead of hardcoded 60. `succeed/1` and `fail/1` still raise (intentional
— they're the "crash on error" convenience wrappers).

67 tests passing, `nix flake check` green.

---

## 2026-02-06: credo cleanup (done)

fixed 4 of 5 credo --strict issues (5th is a legit TODO placeholder):
- number formatting: `3600_000` → `3_600_000` in driver.ex
- alias ordering in machine_test.exs
- nested-too-deep in `do_execute` — flattened with `with`
- nested-too-deep in `VirtConsole.connect` — extracted `accept_or_close`/`wait_or_close` helpers

64 tests passing, `nix flake check` green, only remaining credo issue is the TODO tag.

---

## 2026-02-06: hypervisor abstraction complete (done)

all 4 phases from PLAN.md implemented:

### phase 1: bugfixes
- added missing `handle_call(:booted?)` — fixed 4 test failures
- removed dead code (`connect_shell/3`, `flush_port_messages/1`)

### phase 2: Backend behaviour
- `Machine.Backend` behaviour with 10 callbacks
- `Backend.QEMU` extracted from machine.ex (Port.open, QMP, shell)
- `Backend.Mock` wraps injected pids for unit tests
- Machine GenServer refactored to delegate to backend
- port exit tracking via `handle_port_exit` callback

### phase 3: Shell.Transport behaviour
- `Shell.Transport` behaviour with connect/close callbacks
- `Transport.VirtConsole` extracted from shell.ex (unix socket listen/accept)
- Shell GenServer refactored to use pluggable transport

### phase 4: docs
- ARCHITECTURE.md rewritten to match current code
- progress.md updated

64 tests passing, `nix flake check` green.

---

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
