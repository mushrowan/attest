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
- [x] diagnostic logging for vsock transport (connect attempt reasons, FC liveness check)
- [x] `firecrackerPackage` parameter in make-test.nix

## in progress

### 3. snapshot/restore for fast VM cloning
- [x] forked FC, patched unwrap() panics in vsock event handler
- [x] built patched FC 1.16.0-dev via flake input
- [x] confirmed: **NOT caused by unwrap() panics** (same behaviour with patch)
- [ ] root cause still unknown — vsock UDS listener dies after first connect post-restore
- symptoms:
  - first connect: `:closed` (kernel accepts, muxer closes stream)
  - all subsequent: `:econnrefused` (listener socket gone)
  - FC API thread stays alive (responds to HTTP)
  - permanent — 120s of retries all fail
- next steps to try:
  - add println! instrumentation to FC muxer to trace what happens on first connect
  - check if FC main thread panics/exits (port exit messages)
  - check FC's own log file for errors post-restore
  - try using `--log-path` on the new FC process to capture restore logs

### 9. use wait_all in railscale test scripts
- [x] `Attest.wait_all/2` implemented and tested
- [ ] update module-smoke-attest.nix in railscale to use it

## remaining

### 7. mix release instead of escript
- [ ] switch from escript to mix release in package.nix
- saves ~600ms per test run (no BEAM decompression)

### 8. nix eval overhead
- [ ] profile make-test.nix evaluation time
- module-smoke: ~27s nix eval + sandbox vs ~20s VM execution
- python's simpler nix expressions eval faster

### huge pages (ready but not enabled)
- wired through make-test.nix as `hugePages = true`
- FC docs claim up to 50% faster boot
- requires host: pre-allocated hugetlbfs pool + sandbox path
- also faster snapshot restore (fewer page table entries)
