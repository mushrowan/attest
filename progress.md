# attest

## status

208 tests, `nix flake check` green, 0 flaky tests

### closure optimisation results

```
                   before    after     reduction
attest binary       7.5GB    296MB     -96%
module-smoke drv    7.8GB    2.5GB     -68%
```

optimisations applied:
- vmlinux extracted to own derivation (eliminates linux-dev/rustc/llvm/gcc)
- headless erlang (eliminates wx/gtk/webkitgtk)
- shared store image (one erofs for all nodes instead of one per node)
- idiomatic package.nix using escriptBinName

### benchmark (railscale, `nix build --rebuild`)

```
test                  python/QEMU  attest/FC  speedup
module-smoke (4 VMs)      41s        47s       0.8x
policy-reload (1 VM)      24s        10s       2.4x
cli-integration (3 VMs)  383s       261s       1.4x
TOTAL                    448s       318s       1.4x
```

attest wins on policy-reload (2.4x) and cli-integration (1.4x).
module-smoke is ~tied (nix eval overhead on complex multi-node expressions).

### what's built
- machine GenServer with Backend behaviour (14 callbacks)
- Backend.QEMU, Backend.Firecracker, Backend.CloudHypervisor, Backend.Mock
- shell GenServer with Transport behaviour (VirtConsole, Vsock)
- QMP GenServer with greeting/negotiation, async event filtering
- driver GenServer with start_all, global timeout, VLan lifecycle, graceful shutdown
- full machine ops: execute, succeed, fail, sleep, wait_for_unit, wait_for_open_port, shutdown, reboot, screenshot, send_key, send_chars, send_console, block/unblock, forward_port, copy_from_vm, copy_from_host_via_shell, snapshots, get_tty_text, get_console_log, systemctl, get_unit_info, get_unit_property, wait_until_succeeds/fails, wait_for_file, wait_for_console_text, wait_until_tty_matches, wait_for_closed_port, wait_for_open_unix_socket, start_job/stop_job, crash
- nix integration: StartCommand, CLI, TestScript, make-test.nix, driver.nix, run.nix
- VLan with VDE switch management, deterministic MACs, QEMU NIC flags
- MachineConfig backend-agnostic JSON config parser
- firecracker: make-rootfs.nix, test-instrumentation.nix, snapshot/restore, split store
- cloud-hypervisor: REST API lifecycle, vsock shell, reuses FC rootfs/store
- TAP + bridge networking for multi-VM tests (user+net namespace)
- OCR module: tesseract + imagemagick, 3 parallel variants
- railscale: module-smoke, policy-reload, cli-integration all ported

## next
- test DSL as alternative to raw elixir scripts
- `wait_all` helper for parallel multi-VM readiness checks
- mix release instead of escript (~800ms → ~200ms startup)
- in-guest screenshots via xvfb + imagemagick (non-QEMU backends)
