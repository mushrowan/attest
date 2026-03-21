# progress

## 2026-03-21

- FC performance: `enable_pci` (virtio-pci/MSI-X), `pmem_devices` (virtio-pmem), VMClock (auto in v1.15)
- updated firecracker input from fork to upstream v1.15.0 (vsock fix merged upstream)
- colocated jj, updated AGENTS.md for jj workflow
- added SSH backend/transport, CH pre-built snapshots, Transport send/recv refactor
- removed dead code, fixed stale docs, big docs cleanup
- 275 tests, flake check green
