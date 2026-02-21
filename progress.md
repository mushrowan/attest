# attest

## status

214 tests, `nix flake check` green

### closure optimisation results

```
                   before    after     reduction
vmlinux extract    7.8GB     5.2GB     -2.6GB
shared store       5.2GB     2.5GB     -2.7GB
total              7.8GB     2.5GB     -68%
```

### snapshot/restore

- root cause of original failure: guest kernel 6.18 triple-faults after restore
- fix: `boot.kernelPackages = pkgs.linuxPackages_6_1` (FC supports 5.10/6.1 only)
- vsock muxer works fine — the VM itself was crashing
- pre-built snapshot support: `usePrebuiltSnapshots = true` in make-test.nix
  - snapshot derivation cached by nix (only rebuilds when NixOS config changes)
  - test restores from snapshot in ~87ms instead of ~5s cold boot
  - `nix build --rebuild` only re-runs the test script

### benchmark (railscale, `nix build --rebuild`)

```
test                         python/QEMU  attest/FC  FC+snapshot  speedup
policy-reload (1 VM)              27s        11s         5s        5.4x
module-smoke (4 VMs)              41s        48s         -         0.8x
cli-integration (3 VMs)          402s       265s         -         1.5x
```

## recent changes

- snapshot/restore working with kernel 6.1
- pre-built snapshot derivation (make-snapshot.nix)
- `usePrebuiltSnapshots` option in make-test.nix
- `Attest.state_dir/1` API
- firecracker fork as flake input with update script
- deterministic state dir (no random suffix)
