# progress

## 2026-03-21

- added SSH backend (`Backend.SSH`) for managing remote hosts. connects over SSH, runs commands via shell protocol. no hypervisor. 271 tests, flake check green.
- fixed SSH transport in nix sandbox (always provide `user_dir` to avoid `~/.ssh` access).
- fixed stale CH moduledoc (block/unblock already works via MicroVM macro), added tests.

## 2026-03-20

- added SSH transport, refactored Transport behaviour with send/recv callbacks.
- added CH pre-built snapshot support. removed dead `Driver.run_tests`. dropped live migration.
