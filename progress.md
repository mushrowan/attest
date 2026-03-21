# progress

## 2026-03-20

- added SSH transport (`Transport.SSH`) for remote VM support. bridge GenServer owns SSH channel, buffers `{:ssh_cm, ...}` messages for synchronous send/recv. tested against local Erlang SSH daemon. 251 tests, flake check green.
- refactored Transport behaviour: added `send/recv` callbacks, Shell now uses transport-agnostic send/recv instead of `:gen_tcp` directly. renamed `Shell.socket` to `Shell.conn`.
- added pre-built snapshot support to cloud-hypervisor backend (`snapshot_path` config).
- removed dead `Driver.run_tests/1` and `:test_script` field.
- dropped live migration from future work (snapshot formats are hypervisor-specific).
