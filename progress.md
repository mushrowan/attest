# progress

## 2026-03-21

- improved CLI help with `run`, `--quiet`, and `--verbose`
- moved VM console output behind debug logging
- quieted expected task and socket-close test noise where possible
- switched SSH transport tests to exec mode to avoid interactive `ssh_cli` crashes
- default nix driver runs with `--quiet`, while explicit `extraDriverArgs` can opt back in
- driver now writes per-machine `console.log` artifacts and reports paths on test failure
- added per-machine artifact `metadata.json`
- unit tests now capture logs by default
- fixed CH raw disk `image_type` and FC snapshot load `mem_backend` API warnings
- updated flake inputs and Hex deps
- nix package dependency hashes refreshed for updated lock files
- `mix test` and package/test nix builds green, full flake check still building after cache misses
- FC performance: `enable_pci` (virtio-pci/MSI-X), `pmem_devices` (virtio-pmem), VMClock (auto in v1.15)
- updated firecracker input from fork to upstream v1.15.0 (vsock fix merged upstream)
- colocated jj, updated AGENTS.md for jj workflow
- earlier: SSH backend/transport, CH pre-built snapshots, transport refactor, docs cleanup
