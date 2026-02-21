# performance todo

## current benchmark (railscale, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  FC+snapshot  speedup
policy-reload (1 VM)            27s        11s         5s        5.4x
module-smoke (4 VMs)            41s        48s         -         0.8x
cli-integration (3 VMs)        402s       265s         -         1.5x
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
- [x] **snapshot/restore working** — kernel 6.1 fix, vsock muxer was fine
- [x] **pre-built snapshot derivations** — `usePrebuiltSnapshots = true` in make-test.nix
  - `make-snapshot.nix` boots VMs, snapshots at multi-user.target (cached by nix)
  - `--rebuild` only re-runs test script, not the boot
  - VM restore in ~87ms, policy-reload down from 11s to 5s
- [x] benchmark snapshot restore in railscale (`policy-reload-snapshot.nix`)
- [x] deterministic state dir (dropped random suffix so snapshot paths match)

## remaining

### mix release instead of escript
- [ ] switch from escript to mix release in package.nix
- saves ~600ms per test run (no BEAM decompression)

### nix eval overhead
- [ ] profile make-test.nix evaluation time
- module-smoke: ~27s nix eval + sandbox vs ~20s VM execution
- python's simpler nix expressions eval faster
- snapshot tests amplify this: 87ms restore but 30s nix overhead

### use wait_all in railscale test scripts
- [x] `Attest.wait_all/2` implemented and tested
- [ ] update module-smoke-attest.nix in railscale to use it

### snapshot multi-VM tests
- [ ] snapshot-backed module-smoke (4 VMs restored from snapshots)
- [ ] snapshot-backed cli-integration (3 VMs)
- each node has different NixOS config so needs separate snapshot

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- FC docs claim up to 50% faster boot
- requires host: pre-allocated hugetlbfs pool + sandbox path
- also faster snapshot restore (fewer page table entries)
