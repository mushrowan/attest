# progress log

## 2026-02-06: snapshot create/restore (done)

- `Backend.snapshot_create/2`, `Backend.snapshot_load/2`, `Backend.restore_from_snapshot/2` callbacks
- `snapshot_create` — PATCH /vm to pause, PUT /snapshot/create
- `snapshot_load` — PUT /snapshot/load, PATCH /vm to resume (existing FC process)
- `restore_from_snapshot` — full lifecycle: kill old FC, spawn fresh, load, resume, reconnect shell via vsock
- `Machine.snapshot_create/2`, `Machine.snapshot_restore/2` GenServer calls
- `snapshot_restore` uses `restore_from_snapshot` and updates Machine shell pid
- top-level `NixosTest.snapshot_create/2`, `NixosTest.snapshot_restore/2`
- Backend.QEMU and Backend.Mock return `{:error, :unsupported}`

123 tests passing, `nix flake check` green.

---

## 2026-02-06: Backend.Firecracker (done)

### transport
- `Transport.Vsock` — CONNECT protocol over firecracker's vsock UDS
- waits for backdoor ready message like VirtConsole
- Shell updated to accept custom `transport_config`

### REST API client
- `Firecracker.API` — hand-rolled HTTP/1.1 over UDS, no external deps
- `put/3`, `patch/3`, `get/2` with JSON encode/decode

### backend
- `Backend.Firecracker` — full Backend behaviour implementation
- spawns firecracker, configures via API (logger, machine-config, boot-source,
  drives, vsock, network interfaces), boots, connects shell via vsock
- shutdown via poweroff, halt via SendCtrlAltDel + force kill
- block/unblock via host `ip link set` on TAP interfaces
- unsupported: screenshot, send_key, forward_port, send_console

### also
- `send_console/2` — writes to QEMU stdin (serial console)

118 tests passing, `nix flake check` green.

---

## 2026-02-06: tty text, convenience wrappers, copy_from_vm (done)

- `get_tty_text/2` — read `/dev/vcs<N>` virtual terminal content
- `wait_until_tty_matches/4` — poll VT against regex
- `wait_for_closed_port/3` — poll until TCP port is closed
- `wait_for_open_unix_socket/3` — poll until unix socket exists
- `start_job/2`, `stop_job/2` — systemctl start/stop wrappers
- `copy_from_vm/3` — base64 file transfer from guest to host

100 tests passing, `nix flake check` green.

---

## 2026-02-06: shell reconnect for reboot (done)

- `Shell.reconnect/2` — closes old socket, calls transport.connect again
- `Machine.reboot/2` — sends ctrl-alt-delete then waits for shell reconnect
- machine fully usable after reboot returns

93 tests passing, `nix flake check` green.

---

## 2026-02-06: block/unblock, forward_port, reboot (done)

### network control
- `block/1` — QMP `set_link` to disable inter-VM network (virtio-net-pci.1)
- `unblock/1` — QMP `set_link` to re-enable inter-VM network
- new Backend callbacks: `block/1`, `unblock/1`

### port forwarding
- `forward_port/3` — QMP `human-monitor-command` for SLIRP `hostfwd_add`
- new Backend callback: `forward_port/3`

### reboot
- `reboot/1` — sends ctrl-alt-delete via QMP, marks machine disconnected
- shell reconnection deferred (needs transport layer changes)

all functions in Machine + NixosTest top-level API.
92 tests passing, `nix flake check` green.

---

## 2026-02-06: earlier (condensed)

- console log: `get_console_log/1`, `wait_for_console_text/3` — port data accumulation
- systemd introspection: `get_unit_info/2`, `get_unit_property/3`, `require_unit_state/3`
- file transfer: `copy_from_host_via_shell/3`
- keyboard: `send_key/2`, `send_chars/3`, `char_to_key/1`
- retry helpers: `wait_until_succeeds/3`, `wait_until_fails/3`, `wait_for_file/3`
- convenience: `systemctl/2`, `crash/1`
- error handling: all handle_call paths return `{:error, reason}` tuples
- credo cleanup: flattened nesting, number format, alias ordering
- typespecs on all public functions, dialyzer clean
- hypervisor abstraction: Backend behaviour (14 callbacks), Backend.QEMU, Backend.Mock
- Shell.Transport behaviour: Transport.VirtConsole extracted from shell.ex

---

## 2026-01-31: earlier (condensed)

- integration tests with real QEMU VM (boot → execute → wait_for_unit → shutdown)
- CLI: `eval` and `eval-file` subcommands
- QMP: skip async events, retry connection 10x
- graceful shutdown: `Machine.shutdown/2`, `Machine.halt/2`, `Machine.wait_for_shutdown/2`
- multi-VM: fixed env var syntax, socket timing, shell timeout
- Driver: start_all/1, get_machine/2, manages MachineSupervisor
