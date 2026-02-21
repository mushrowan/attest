# performance todo

## current benchmark (railscale, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  speedup
module-smoke (4 VMs)            41s        47s      0.8x
policy-reload (1 VM)            24s        10s      2.4x
cli-integration (3 VMs)        383s       261s      1.4x
TOTAL                          448s       318s      1.4x
```

## done

- [x] extract vmlinux to own derivation (-2.4GB closure)
- [x] headless erlang (-200MB closure)
- [x] shared store image across nodes (-5.4GB for 4-VM tests)
- [x] idiomatic package.nix with escriptBinName
- [x] entropy device (virtio-rng) — enabled by default
- [x] huge pages support — wired through but off by default (needs host hugetlbfs)
- [x] `Attest.wait_all/2` — concurrent multi-machine operations
- [x] firecracker fork infrastructure (`mushrowan/firecracker`, flake input, update script)
- [x] `firecrackerPackage` parameter in make-test.nix
- [x] **snapshot/restore working** — root cause was guest kernel 6.18 triple-faulting after restore. FC only supports 5.10/6.1 for snapshots. using `linuxPackages_6_1` fixes it. vsock muxer was fine all along

## remaining

### 7. mix release instead of escript
- [ ] switch from escript to mix release in package.nix
- saves ~600ms per test run (no BEAM decompression)

### 8. nix eval overhead
- [ ] profile make-test.nix evaluation time
- module-smoke: ~27s nix eval + sandbox vs ~20s VM execution
- python's simpler nix expressions eval faster

### 9. use wait_all in railscale test scripts
- [x] `Attest.wait_all/2` implemented and tested
- [ ] update module-smoke-attest.nix in railscale to use it

### snapshot/restore follow-ups
- [ ] expose `snapshotKernelPackages` option in make-test.nix for tests that use snapshots
- [ ] benchmark snapshot restore time (should be ~85ms from earlier tests)
- [ ] wire snapshot/restore into railscale tests for fast multi-VM cloning

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- FC docs claim up to 50% faster boot
- requires host: pre-allocated hugetlbfs pool + sandbox path
- also faster snapshot restore (fewer page table entries)
