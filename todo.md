# performance todo

## current benchmark (railscale, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  speedup
module-smoke (4 VMs)            41s        47s      0.8x
policy-reload (1 VM)            24s        10s      2.4x
cli-integration (3 VMs)        383s       261s      1.4x
TOTAL                          448s       318s      1.4x
```

## time breakdown (module-smoke, 4 VMs)

```
escript startup + driver init     0.3s
FC API config (4 VMs parallel)    0.4s
VM boot → vsock ready             6.4s
wait_for_unit (already up)        0.1s
4 × Process.sleep(3000) SEQ      12.0s   ← test script, can't change
shutdown                           1.0s
                          TOTAL  ~20s
```

## firecracker-specific optimisations

### 1. huge pages (`huge_pages: "2M"`)
- [ ] add `huge_pages` field to machine-config API call
- [ ] add `huge_pages` option to make-test.nix
- [ ] document host requirement: pre-allocated hugetlbfs pool
- FC docs claim **up to 50% faster boot** and faster snapshot restore
- requires `nix.settings.extra-sandbox-paths = ["/dev/hugepages"]` or similar
- simple: one field in `/machine-config` PUT

### 2. entropy device (`/entropy`)
- [ ] configure `/entropy` endpoint during VM setup
- [ ] add `CONFIG_HW_RANDOM_VIRTIO` to test-instrumentation kernel modules
- virtio-rng gives guest immediate high-quality randomness
- avoids any entropy starvation stalls during boot
- cheap to add, might save a few hundred ms

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
- needs `track_dirty_pages: true` in machine-config

### 5. MMDS for host→guest config
- [ ] configure MMDS on network interface
- [ ] use MMDS to pass test parameters instead of shell commands
- not a speed win per se, but enables snapshot/restore signal flow
- guest can poll MMDS to detect restore and signal readiness
- data store is NOT persisted across snapshots (by design)

## non-FC optimisations

### 6. `wait_all` helper
- [ ] add `Attest.wait_all/2` that waits on multiple machines concurrently
- module-smoke does 4 sequential wait_for_unit + 3s sleep = 12s wasted
- concurrent waiting would save ~9s on module-smoke

### 7. mix release instead of escript
- [ ] switch from escript to mix release in package.nix
- escripts decompress BEAM files on every invocation (~800ms)
- releases have pre-extracted BEAMs (~200ms startup)
- saves ~600ms per test run

### 8. nix eval overhead
- [ ] profile make-test.nix evaluation time
- module-smoke: 47s total but only ~20s is VM execution
- remaining ~27s is nix evaluation + sandbox setup
- python's simpler nix expressions eval faster
