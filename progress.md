# nixos-test-ng

## status

174 tests, `nix flake check` green

### what's built
- Machine GenServer with Backend behaviour (14 callbacks)
- Backend.QEMU, Backend.Firecracker, Backend.Mock
- Shell GenServer with Transport behaviour (VirtConsole, Vsock)
- QMP GenServer with greeting/negotiation, async event filtering
- Driver GenServer — start_all, get_machine, global timeout, VLan lifecycle, graceful shutdown
- full machine ops: execute, succeed, fail, sleep, wait_for_unit, wait_for_open_port, shutdown, reboot, screenshot, send_key, send_chars, send_console, block/unblock, forward_port, copy_from_vm, copy_from_host_via_shell, snapshots (firecracker), get_tty_text, get_console_log, systemctl (with user: opt), get_unit_info, get_unit_property, wait_until_succeeds/fails, wait_for_file, wait_for_console_text, wait_until_tty_matches, wait_for_closed_port, wait_for_open_unix_socket, start_job/stop_job (with user: opt), crash
- nix integration: StartCommand, CLI, TestScript, make-test.nix, driver.nix, run.nix
- VLan — VDE switch management, deterministic MACs, QEMU NIC flags
- smoke tests: single-VM and multi-node (server + client) passing in `nix flake check`
- driver.nix includes vde2 in PATH for VLan support

## next

### missing machine methods
- OCR / screenshot text extraction

### firecracker nix integration
- vmlinux kernel extraction from NixOS config
- ext4 rootfs builder
- vsock backdoor NixOS service/module
- firecracker make-test.nix variant

### Backend.CloudHypervisor
- REST API client (similar to firecracker)
- virtconsole shell (reuses Transport.VirtConsole)
- cloud-hypervisor nix integration

### other
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
