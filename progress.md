# attest

## status

208 tests, `nix flake check` green, 0 flaky tests (was ~20% failure rate)

### what's built
- Machine GenServer with Backend behaviour (14 callbacks)
- Backend.QEMU, Backend.Firecracker, Backend.Mock
- Shell GenServer with Transport behaviour (VirtConsole, Vsock)
- QMP GenServer with greeting/negotiation, async event filtering
- Driver GenServer — start_all, get_machine, global timeout, VLan lifecycle, graceful shutdown
- full machine ops: execute, succeed, fail, sleep, wait_for_unit, wait_for_open_port, shutdown, reboot, screenshot, send_key, send_chars, send_console, block/unblock, forward_port, copy_from_vm, copy_from_host_via_shell, snapshots (firecracker), get_tty_text, get_console_log, systemctl (with user: opt), get_unit_info, get_unit_property, wait_until_succeeds/fails, wait_for_file, wait_for_console_text, wait_until_tty_matches, wait_for_closed_port, wait_for_open_unix_socket, start_job/stop_job (with user: opt), crash
- nix integration: StartCommand, CLI, TestScript, make-test.nix, driver.nix, run.nix
- VLan — VDE switch management, deterministic MACs, QEMU NIC flags
- QEMU smoke tests: single-VM and multi-node passing in `nix flake check`
- MachineConfig — backend-agnostic JSON config parser (QEMU + Firecracker)
- CLI --machine-config flag with env var fallback, firecracker rootfs copy+chmod
- firecracker nix integration: make-rootfs.nix, test-instrumentation.nix, make-test.nix
- firecracker smoke test passing in `nix flake check` (boot, execute, shutdown)
- vsock transport retry on closed/econnrefused during guest boot
- OCR module: tesseract + imagemagick preprocessing, 3 parallel variants
- Machine: get_screen_text, get_screen_text_variants, wait_for_text
- Backend.CloudHypervisor: REST API lifecycle, vsock shell, MachineConfig parser
- cloud-hypervisor nix integration: test-instrumentation.nix (reuses vsock-backdoor), make-test.nix
- cloud-hypervisor smoke test passing in `nix flake check` (boot, execute, shutdown)
- API.put_no_body/2 for bodyless PUT endpoints (cloud-hypervisor rejects empty {})
- split store: erofs nix store image + minimal ext4 rootfs (fc 35s→5.4s, ch 36s→4.4s)
- dhcpcd disabled in test VMs (was 30s timeout with no network)
- firecracker snapshot/restore integration test (84ms restore)
- `nix build .#bench` — backend benchmark (qemu, fc, ch, fc-snapshot)
- flaky test fix: unique machine names + synchronous terminate cleanup
- line-buffered TCP recv in shell (large outputs split across TCP segments)
- `reboot -f -p` for microVM shutdown (no ACPI), parallel teardown in driver
- railscale integration: module-smoke and policy-reload tests ported to attest
- TAP + bridge networking for multi-VM firecracker tests (user+net namespace)
- static IP assignment, /etc/hosts, virtio_net kernel module in test-instrumentation
- MachineConfig parses tap_interfaces from JSON
- cloud-hypervisor networking: same bridge+TAP approach, block/unblock via ip link
- cloud-hypervisor network integration test (alice + bob ping by IP and hostname)
- railscale cli-integration-attest: full parity with python suite (STUN, cross-user taildrop, ephemeral/reusable json, user delete constraint, rate limit headers, lock json, etc)
- README and updated ARCHITECTURE.md

## next
- ~~rename project to **attest**~~ done
- test DSL as alternative to raw elixir scripts
- in-guest screenshots via xvfb + imagemagick (non-QEMU backends)
- `Network` behaviour — TAP + bridge networking abstraction

## research notes

### firecracker viability
- **vsock replaces virtconsole**: host connects to firecracker UDS, sends `CONNECT <port>\n`, gets bidirectional stream to guest. same command protocol, only connection establishment changes
- **snapshot/restore**: boot once, snapshot after systemd ready, restore in ~50-150ms per clone. memory is MAP_PRIVATE mmap (CoW). this is how AWS Lambda works
- **networking**: TAP + linux bridges replace VDE. `ip link set down` replaces `set_link`. `tc`/`netem` adds packet loss/latency/corruption
- **GUI**: xvfb + xdotool inside guest. no pre-boot screen capture, but irrelevant for 99%+ of NixOS tests
- **no virtconsole, no QMP, no VGA** — all replaced by the above

### cloud-hypervisor viability
- has virtconsole and virtiofs (shell backdoor + shared dirs work unchanged)
- REST API instead of QMP
- no VGA/screenshots, no keyboard sim
- less compelling than firecracker since no snapshot/restore perf story

### ~80%+ of nixpkgs NixOS tests are shell-only
tests using only succeed/fail/wait_for_unit/wait_for_open_port don't need VGA, keyboard, or any QEMU-specific features — can run on any backend
