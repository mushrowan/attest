# attest

## status

214 tests, `nix flake check` green

### benchmark (railscale, `nix build --rebuild`, warm cache)

```
test                       python/QEMU  attest/FC  FC+snapshot  speedup
module-smoke (4 VMs)            28s         9s         -         3.1x
policy-reload (1 VM)            22s         7s         3s        3.1-7.3x
cli-integration (3 VMs)        377s       259s         -         1.4x
TOTAL                          427s       275s         -         1.5x
```

### closure optimisation

```
                   before    after     reduction
vmlinux extract    7.8GB     5.2GB     -2.6GB
shared store       5.2GB     2.5GB     -2.7GB
total              7.8GB     2.5GB     -68%
```

### snapshot/restore

- pre-built snapshot support: `usePrebuiltSnapshots = true` in make-test.nix
- snapshot derivation cached by nix (only rebuilds when NixOS config changes)
- VM restore in ~87ms, policy-reload 7s → 3s with snapshots

### recent refactoring

- extracted keyboard module (machine/keyboard.ex)
- shared backend helpers in Backend module (wait_for_file, close_port, etc)
- deduplicated FC/CH machine config parsing
- net -70 lines across all changes
