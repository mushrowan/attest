# progress

## 2026-03-21

- added SSH backend and transport for remote host management
- added CH pre-built snapshot support (mirrors firecracker's `snapshot_path`)
- refactored Transport behaviour with `send/recv` callbacks (Shell no longer calls `:gen_tcp` directly)
- removed dead `Driver.run_tests/1` (deadlock-prone, unused)
- fixed stale CH block/unblock docs (already worked via MicroVM macro)
- dropped live migration from roadmap (not practical)
- big docs cleanup: README, ARCHITECTURE, AGENTS all synced with current code
- 271 tests, flake check green
