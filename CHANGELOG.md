# changelog

## unreleased

### backends
- **nspawn backend** -- systemd-nspawn containers, no KVM needed. works in CI and cheap VMs
- **SSH backend** -- connect to already-running hosts (cloud VMs, physical machines, containers)
- **CH pre-built snapshots** -- `snapshot_path` config for cloud-hypervisor, mirrors firecracker's pattern

### transports
- **SSH transport** -- shell commands over SSH channels via bridge GenServer
- **transport refactor** -- added `send/recv` callbacks, Shell no longer calls `:gen_tcp` directly

### firecracker performance
- **`enable_pci`** -- virtio-pci transport with MSI-X interrupts (>= 1.13)
- **`pmem_devices`** -- virtio-pmem for read-only images, bypasses block layer (>= 1.14)
- **`io_engine`** -- async I/O via io_uring for block devices (kernel >= 5.10.51)
- **`cache_type`** -- block device caching strategy ("Unsafe" or "Writeback")
- **VMClock** -- auto-enabled in v1.15, fixes time drift after snapshot restore
- **updated to upstream firecracker v1.15.0** (was on a fork for vsock fix, now merged)

### performance
- **guest-side polling** -- `wait_for_unit` and `wait_for_open_port` now use single guest-side commands with 100ms intervals instead of repeated 1s host-side polling. test suite dropped from ~27s to ~20s

### ease of use
- **`debug_boot`** -- one config flag for verbose systemd boot output (FC + CH)
- **`Attest.journal/2`** -- fetch journal logs with unit/line/boot filters
- **boot diagnostics on timeout** -- auto-logs failed units and last 30 journal lines when wait_for_unit/port fails
- **debugging guide** in README -- interactive IEx, common hang causes

### code quality
- fixed all 13 credo strict warnings (nesting, complexity, implicit try, aliases)
- added missing `@impl true` annotations on GenServer callbacks
- typespec audit -- coverage confirmed excellent, added missing spec
- removed dead `Driver.run_tests/1` (deadlock-prone, unused)
- fixed stale docs (CH block/unblock, shell transport list)
- replaced 78 em dashes with `--` across codebase
- big docs cleanup -- README, ARCHITECTURE, AGENTS all synced

### other
- jj colocated
- dropped live migration from roadmap (not practical)
- 304 tests (up from 242), zero credo warnings, zero TODOs
