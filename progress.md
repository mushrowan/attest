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
- removed nix build Jason/ExCoveralls warnings by xref-excluding Jason and adding optional CAStore
- quieted legacy integration scripts by moving progress logs to debug and removing wrapper banners
- added dogfood timing instrumentation for driver runs and machine start/wait/execute/shutdown operations
- made legacy multi-VM integration start and shut down machines concurrently
- removed a fixed QEMU shell-listener sleep by waiting for the socket
- set `ERL_FLAGS=+fnu` in nix checks and VM runners to remove latin1 warnings
- slimmed nix test dependency fetches to test-only deps
- replaced fixed-output Mix dependency hashes with generated `nix/mix-deps.nix`
- added `mix deps.nix` alias and `nupd` devshell command for full dependency updates
- ran `nupd`; only nixpkgs advanced, Hex deps unchanged
- made `nupd` validate with `mix test` and `nix build .#attest --no-link`
- overrode devshell `mix2nix` to use the project headless BEAM package set
- quieted successful integration logs and removed test-check release fixup noise
- added non-failing `perf-budget` check documenting the current warm flake target
- made `perf-budget` warn on timings from VM check `timings.json` outputs
- removed coverage tooling from the ordinary nix test dependency set
- added backend phase timings to machine artifact metadata
- added BEAM cpu/reduction counters to operation and backend timing metadata
- made `perf-budget` emit backend phase summaries as `backend-phases.tsv`
- updated flake inputs and Hex deps
- nix package dependency hashes refreshed for updated lock files
- `mix test` and package/test nix builds green, full flake check still building after cache misses
- FC performance: `enable_pci` (virtio-pci/MSI-X), `pmem_devices` (virtio-pmem), VMClock (auto in v1.15)
- updated firecracker input from fork to upstream v1.15.0 (vsock fix merged upstream)
- colocated jj, updated AGENTS.md for jj workflow
- earlier: SSH backend/transport, CH pre-built snapshots, transport refactor, docs cleanup
