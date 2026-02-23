# attest

## status

214 tests, `nix flake check` green

### benchmark (railscale, bench.sh)

```
test                       python/QEMU  attest/FC  FC+snapshot  speedup
module-smoke (4 VMs)            41s        29s         -         1.4x
policy-reload (1 VM)            26s         5s         2s        5.2-13x
cli-integration (3 VMs)        410s       149s         -         2.7x
TOTAL                          477s       183s         -         2.6x
```

### closure size

```
                   before    after     reduction
vmlinux extract    7.8GB     5.2GB     -2.6GB
shared store       5.2GB     2.5GB     -2.7GB
total              7.8GB     2.5GB     -68%
```

### recent work

- pre-built snapshot support (`usePrebuiltSnapshots = true`)
- replaced static sleeps with polling in all railscale tests
- extracted keyboard module, shared backend helpers
- deduplicated FC/CH machine config parsing
- fixed credo warnings (aliasing, redundant with clauses)
