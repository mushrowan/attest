# performance todo

## current benchmark (railscale, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  FC+snapshot  speedup
policy-reload (1 VM)            23s         7s         5s        3.3-4.6x
module-smoke (4 VMs)            41s        48s         -         0.8x
cli-integration (3 VMs)        402s       265s         -         1.5x
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
- [x] ~~mix release~~ — measured escript startup at 170ms, not worth switching
- [x] refactor: keyboard module, shared backend helpers, deduplicated config parsing

## remaining

### nix eval overhead
- [ ] profile make-test.nix evaluation time
- attest: 11s eval vs python: 7s eval (warm cache)
- module-smoke: 19s eval (4 NixOS module evaluations)
- inherent to NixOS module system, limited scope for improvement
- `--rebuild` only adds ~0.6s over the test execution time itself

### snapshot multi-VM tests
- [ ] snapshot-backed module-smoke (4 VMs restored from snapshots)
- [ ] snapshot-backed cli-integration (3 VMs)
- note: `--rebuild` rebuilds snapshot derivation too, so no benefit for benchmarks
- benefit is for real dev workflow: change test script, snapshot stays cached

### module-smoke 0.8x regression
- [ ] profile why 4-VM attest is slower than python
- likely: sequential nix eval of 4 NixOS configs + erofs build
- python parallel-evaluates via lib/testing/nodes.nix

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- FC docs claim up to 50% faster boot
- requires host: pre-allocated hugetlbfs pool + sandbox path
