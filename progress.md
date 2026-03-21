# progress

## 2026-03-20

- added pre-built snapshot support to cloud-hypervisor backend. when `snapshot_path` is set in config, `start/1` restores from snapshot (vm.restore + vm.resume) instead of cold booting (vm.create + vm.boot). mirrors firecracker's existing pattern. 245 tests, flake check green.
- removed dead `Driver.run_tests/1` and `:test_script` field (deadlock-prone no-op).
