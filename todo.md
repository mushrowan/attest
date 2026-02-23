# performance todo

## current benchmark (railscale, `nix build --rebuild`, warm cache)

```
test                       python/QEMU  attest/FC  FC+snapshot  speedup
module-smoke (4 VMs)            28s         9s         -         3.1x
policy-reload (1 VM)            22s         7s         3s        3.1-7.3x
cli-integration (3 VMs)        377s       259s         -         1.4x
TOTAL                          427s       275s         -         1.5x
```

## done

- [x] extract vmlinux to own derivation (-2.4GB closure)
- [x] headless erlang (-200MB closure)
- [x] shared store image across nodes (-5.4GB for 4-VM tests)
- [x] idiomatic package.nix with escriptBinName
- [x] entropy device (virtio-rng) — enabled by default
- [x] huge pages support — wired through but off by default
- [x] `Attest.wait_all/2` — concurrent multi-machine operations
- [x] `wait_all` used in railscale module-smoke-attest.nix
- [x] firecracker fork infrastructure
- [x] `firecrackerPackage` parameter in make-test.nix
- [x] snapshot/restore working — kernel 6.1 fix
- [x] pre-built snapshot derivations — `usePrebuiltSnapshots = true`
- [x] deterministic state dir
- [x] ~~mix release~~ — escript startup is 170ms, not worth switching
- [x] ~~module-smoke 0.8x regression~~ — was nix eval overhead, actual is 3.1x faster
- [x] refactor: keyboard module, shared backend helpers, deduplicated config parsing

## remaining

### cli-integration 1.4x
- [ ] profile where the remaining gap is (259s vs 377s)
- mostly sequential test steps, limited parallelism opportunity
- might benefit from snapshot restore for the 3 VMs

### nix eval overhead
- attest: 11-19s eval vs python: 7s eval (warm cache)
- inherent to NixOS module system for each guest config
- not measured in --rebuild benchmarks (only affects first build)
- possible fix: pre-evaluate and cache NixOS module output

### snapshot multi-VM tests
- [ ] snapshot-backed cli-integration (3 VMs)
- benefit is for dev workflow: change test script, snapshot stays cached

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- requires host: pre-allocated hugetlbfs pool + sandbox path
