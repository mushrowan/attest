# performance todo

## current benchmark (railscale, bench.sh)

```
test                       python/QEMU  attest/FC  FC+snapshot  speedup
module-smoke (4 VMs)            41s        29s         -         1.4x
policy-reload (1 VM)            26s         5s         2s        5.2-13x
cli-integration (3 VMs)        410s       149s         -         2.7x
TOTAL                          477s       183s         -         2.6x
```

## done

- [x] extract vmlinux to own derivation (-2.4GB closure)
- [x] headless erlang (-200MB closure)
- [x] shared store image across nodes (-5.4GB for 4-VM tests)
- [x] idiomatic package.nix with escriptBinName
- [x] entropy device (virtio-rng)
- [x] huge pages support (wired through, off by default)
- [x] `Attest.wait_all/2` and used in railscale tests
- [x] firecracker fork + `firecrackerPackage` parameter
- [x] snapshot/restore with kernel 6.1
- [x] pre-built snapshot derivations
- [x] deterministic state dir
- [x] ~~mix release~~ — escript 170ms, not worth it
- [x] refactor: keyboard module, shared backend helpers, deduped config
- [x] credo warnings fixed
- [x] **sleep → polling in all railscale tests** (cli-int: 259s → 149s)

## remaining

### snapshot multi-VM tests
- [ ] snapshot-backed cli-integration (3 VMs)
- benefit is for dev workflow: change test script, snapshot stays cached
- `--rebuild` rebuilds snapshots too (nix semantics), so no bench benefit

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- requires host: pre-allocated hugetlbfs pool + sandbox path
