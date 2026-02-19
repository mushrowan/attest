# performance todo

## benchmark results (railscale tests, `nix build --rebuild`)

```
test                       python/QEMU  attest/FC  speedup
module-smoke (4 VMs)            37s        72s      0.5x
policy-reload (1 VM)            24s        38s      0.6x
cli-integration (3 VMs)        382s       329s      1.2x
```

attest wins on long-running tests but loses badly on short ones.

## breakdown (module-smoke-attest, 4 VMs)

```
nix sandbox overhead       ~53s     (7.5GB closure copy into sandbox)
escript startup             0.8s
rootfs copy                 0.3s
VM boot + test + shutdown  18.2s
TOTAL                      72s
```

python/QEMU has ~10s sandbox overhead because its closure is much smaller.

## closure analysis (7.5GB)

```
4 × nix-store-image       3.5GB    (erofs store imgs, legitimate)
rustc                      995MB    (pulled by linux-dev → rust kernel support)
linux-dev                  580MB    (vmlinux path references entire dev output)
llvm                       541MB    (pulled by rustc)
gcc                        265MB    (pulled by linux-dev)
webkitgtk                  162MB    (pulled by erlang → wxwidgets)
linux-modules              133MB    
python3                    107MB    (pulled by erlang build?)
erlang                     118MB    
other                      ~800MB   (systemd, perl, flite, etc)
```

the big wins: strip vmlinux out of linux-dev, use headless erlang

## optimisations

### P0: closure size (~7.5GB → ~4GB target)

- [ ] **copy vmlinux out of linux-dev** — currently `kernel.dev + "/vmlinux"`
  which keeps the entire dev output (580MB) + rustc (995MB) + llvm (541MB)
  + gcc (265MB) alive. instead, `runCommand` to copy just the vmlinux binary
  into its own derivation. saves ~2.4GB
- [ ] **use headless erlang** — `erlang` pulls in `wxwidgets` (34MB) →
  `webkitgtk` (162MB) + gtk chain. use `erlangR27.override { wxSupport = false; }`
  or `beamPackages.erlang_nox`. saves ~200MB
- [ ] **audit remaining closure** — python3, perl, flite, systemd shouldn't
  be runtime deps. check what's pulling them in

### P1: escript startup (~0.8s per run)

- [ ] **build as mix release** — escripts decompress beam files on every
  invocation. a release has pre-extracted beams. ~800ms → ~200ms

### P2: rootfs handling

- [ ] **CoW overlay instead of copying rootfs** — use device-mapper snapshot
  or loopback + overlay so the nix store original stays read-only. eliminates
  the per-VM copy (~5MB each, fast but still unnecessary)

### P3: VM lifecycle

- [ ] **`wait_all` helper** — `start_all` boots VMs in parallel but test
  scripts then do sequential `wait_for_unit` per VM. a `wait_all` that
  waits concurrently would help multi-VM tests
- [ ] **reduce shutdown timeout** — `reboot -f -p` is near-instant but
  we wait up to 30s for process exit. tune down

### P4: test parallelism

- [ ] **independent VMs as separate derivations** — module-smoke's 4 VMs
  are independent. could be 4 parallel nix builds
- [ ] **snapshot-based test isolation** — boot once, restore per test
