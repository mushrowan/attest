# performance todo

## current benchmark (railscale, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  speedup
module-smoke (4 VMs)            41s        47s      0.8x
policy-reload (1 VM)            24s        10s      2.4x
cli-integration (3 VMs)        383s       261s      1.4x
TOTAL                          448s       318s      1.4x
```

needs re-running after entropy + shared store changes

## done

- [x] extract vmlinux to own derivation (-2.4GB closure)
- [x] headless erlang (-200MB closure)
- [x] shared store image across nodes (-5.4GB for 4-VM tests)
- [x] idiomatic package.nix with escriptBinName
- [x] entropy device (virtio-rng) — enabled by default
- [x] huge pages support — wired through but off by default (needs host hugetlbfs)
- [x] `Attest.wait_all/2` — concurrent multi-machine operations

## remaining firecracker-specific

### 3. snapshot/restore for fast VM cloning
- [ ] solve vsock reconnect after restore
- [ ] implement "boot once, snapshot, restore N" pattern
- cold boot: ~6.4s → snapshot restore: ~85ms (75x faster)
- memory is MAP_PRIVATE (CoW), so N restores share base pages
- **blocker**: FC only accepts one vsock UDS connection. if first
  CONNECT arrives before guest driver resets, FC stops listening
  permanently. known issue [#1253]
- possible workarounds:
  - (a) delay CONNECT until guest signals readiness via MMDS
  - (b) use serial console transport after restore instead of vsock
  - (c) patch guest init to re-bind vsock listener after transport reset
  - (d) use diff snapshots + fresh FC process per restore (current approach,
        but vsock UDS still has the race)

### 4. diff snapshots for test isolation
- [ ] depends on snapshot/restore working (#3)
- [ ] boot base VM, snapshot after systemd ready
- [ ] per test case: restore from base, run test, discard
- only dirty pages saved per snapshot (sparse files)
- enables parallel test execution from same base state

### 5. MMDS for host→guest config
- [ ] configure MMDS on network interface
- [ ] use to signal restore readiness (unblocks #3)
- data store NOT persisted across snapshots (by design)

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- FC docs claim up to 50% faster boot
- requires host: `nix.settings.extra-sandbox-paths = ["/dev/hugepages"]`
  and pre-allocated hugetlbfs pool
- also faster snapshot restore (fewer page table entries)

## remaining non-FC

### 7. mix release instead of escript
- [ ] switch from escript to mix release in package.nix
- saves ~600ms per test run (no BEAM decompression)

### 8. nix eval overhead
- [ ] profile make-test.nix evaluation time
- module-smoke: ~27s nix eval + sandbox vs ~20s VM execution
- python's simpler nix expressions eval faster

### 9. use wait_all in railscale test scripts
- [ ] update module-smoke-attest.nix to use `Attest.wait_all/2`
- currently 4 sequential wait_for_unit + sleep(3000) = 12s
- concurrent would be ~3s (limited by longest single VM)
