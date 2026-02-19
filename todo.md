# performance todo

## benchmark results (railscale tests, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  speedup
module-smoke (4 VMs)            41s        47s      0.8x
policy-reload (1 VM)            24s        10s      2.4x
cli-integration (3 VMs)        383s       261s      1.4x
TOTAL                          448s       318s      1.4x
```

## done

- [x] **extract vmlinux** — `runCommand` copies vmlinux out of kernel.dev.
  saved ~2.4GB (linux-dev + rustc + llvm + gcc)
- [x] **headless erlang** — `beam.override { wxSupport = false; }`.
  saved ~200MB (wx + gtk + webkitgtk)
- [x] **shared store image** — one erofs for all nodes in a test.
  module-smoke: 4 × 1.8GB → 1 × 891MB
- [x] **idiomatic package.nix** — escriptBinName, passthru.mixFodDepsAll

## remaining

### P1: escript startup (~0.8s per run)

- [ ] **build as mix release** — escripts decompress beam files on every
  invocation. a release has pre-extracted beams. ~800ms → ~200ms

### P2: rootfs handling

- [ ] **CoW overlay instead of copying rootfs** — use device-mapper snapshot
  or loopback + overlay so the nix store original stays read-only

### P3: VM lifecycle

- [ ] **`wait_all` helper** — `start_all` boots VMs in parallel but test
  scripts then do sequential `wait_for_unit` per VM. concurrent waiting
  would help multi-VM tests

### P4: nix eval overhead

- [ ] **module-smoke nix eval** — 47s vs python's 41s. the attest nix
  expressions evaluate slower (more complex make-test.nix). profiling
  needed to find what's slow
