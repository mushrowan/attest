# attest

NixOS integration test driver in elixir. OTP supervision trees for VM lifecycle,
pluggable backends (QEMU, firecracker, cloud-hypervisor, SSH), elixir test scripts
instead of python.

## quick start

```nix
# flake.nix
{
  inputs.attest.url = "github:mushrowan/attest";

  outputs = { attest, nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      checks.x86_64-linux.my-test =
        import "${attest}/nix/firecracker/make-test.nix" {
          inherit pkgs;
          attest = attest.packages.x86_64-linux.default;
          name = "my-test";
          splitStore = true;
          nodes = {
            server = { pkgs, ... }: {
              services.nginx.enable = true;
              networking.firewall.allowedTCPPorts = [ 80 ];
            };
          };
          testScript = ''
            start_all.()
            Attest.wait_for_unit(server, "nginx.service")
            Attest.wait_for_open_port(server, 80)
            output = Attest.succeed(server, "curl -s http://localhost")
            IO.puts("got: #{String.trim(output)}")
          '';
        };
    };
}
```

```bash
nix build .#checks.x86_64-linux.my-test -L
```

## backends

| backend | boot time | networking | screenshots | snapshots |
|---------|-----------|------------|-------------|-----------|
| QEMU | ~12s | VDE (userspace) | yes (QMP) | no |
| firecracker | ~5s | TAP + bridge | yes (guest) | yes (~85ms restore) |
| cloud-hypervisor | ~4.5s | TAP + bridge | yes (guest) | yes (pre-built or runtime) |
| SSH | n/a | existing | no | no |
| nspawn | ~1s | veth/host | no | no |

the SSH backend connects to already-running hosts (cloud VMs, physical machines,
containers with sshd) rather than managing a hypervisor. the nspawn backend
runs NixOS in a systemd-nspawn container -- no KVM needed, works in CI and
cheap VMs without nested virtualisation.

### split store

for firecracker and cloud-hypervisor, `splitStore = true` uses a compressed
read-only erofs image for `/nix/store` on a second drive, with an overlay for
writability. the rootfs shrinks from ~1.2GB to ~10MB, and the erofs image is
shared across nodes.

## networking

multi-VM tests with firecracker/cloud-hypervisor use real TAP devices on a
bridge, created inside a user+network namespace. nodes get static IPs
(`192.168.{vlan}.{nodeNumber}`) and `/etc/hosts` entries for hostname resolution.

### host setup

TAP device creation needs `/dev/net/tun` exposed in the nix build sandbox.
add this to your NixOS config:

```nix
nix.settings.extra-sandbox-paths = [ "/dev/net/tun" ];
```

then rebuild (`sudo nixos-rebuild switch`). this is only needed for multi-VM
tests with networking -- single-VM tests work without it.

QEMU tests don't need this (they use VDE switches which are entirely userspace).

### how it works

the test runner creates a user namespace (root inside, unprivileged outside)
with a fresh network namespace. inside that namespace it can freely create
bridges, TAP devices, and assign IPs without any real host privileges. firecracker
attaches to the TAP devices. the namespace is torn down when the build finishes.

### usage

networking is enabled automatically when there are multiple nodes, or explicitly
with `enableNetwork = true`:

```nix
import "${attest}/nix/firecracker/make-test.nix" {
  inherit pkgs attest;
  name = "network-test";
  splitStore = true;
  nodes = {
    alice = { pkgs, ... }: {
      environment.systemPackages = [ pkgs.iputils ];
    };
    bob = { pkgs, ... }: {
      environment.systemPackages = [ pkgs.iputils ];
    };
  };
  testScript = ''
    start_all.()
    # alice is 192.168.1.1, bob is 192.168.1.2 (alphabetical order)
    Attest.succeed(alice, "ping -c 1 bob")
    Attest.succeed(bob, "ping -c 1 alice")
  '';
}
```

## test scripts

test scripts are plain elixir. each node name becomes a variable bound to its
machine pid. `start_all` is a function that boots all VMs in parallel.

### available functions

test scripts auto-import `Attest` and `Attest.DSL`, so no prefix needed:

```elixir
# boot
start_all.()

# shell commands
succeed(machine, "command")           # run, raise on non-zero exit
fail(machine, "command")              # run, raise on zero exit
{code, output} = execute(machine, "command")

# wait for state
wait_for_unit(machine, "nginx.service")
wait_for_open_port(machine, 80)

# shutdown
Attest.Machine.shutdown(machine)

# snapshots (firecracker, cloud-hypervisor)
snapshot_create(machine, "/tmp/snap")
snapshot_restore(machine, "/tmp/snap")

# screenshots (QEMU -- via QMP)
screenshot(machine, "/tmp/screen.ppm")

# screenshots (firecracker/cloud-hypervisor -- via guest shell)
guest_screenshot(machine, "/tmp/screen.png")                 # fbgrab (default)
guest_screenshot(machine, "/tmp/screen.png", method: :x11)   # X11

# OCR (QEMU only, needs tesseract)
Attest.Machine.get_screen_text(machine)
Attest.Machine.wait_for_text(machine, "login:", timeout: 30_000)
```

### DSL helpers

```elixir
# labelled sections with timing
subtest "nginx is running", fn ->
  wait_for_unit(server, "nginx.service")
  wait_for_open_port(server, 80)
end

# string assertions
output = succeed(machine, "hostname")
assert_contains(output, "server")
assert_matches(output, ~r/server\d+/)

# retry with backoff
retry attempts: 10, delay: 1000 do
  succeed(machine, "curl http://server")
end

# parallel readiness
wait_all.([server, client], fn m ->
  wait_for_unit(m, "multi-user.target")
end)
```

## benchmarks

run `nix build .#bench -L` to compare backends:

```
qemu:             boot=7949  exec=62   total=11160ms
firecracker:      boot=5168  exec=12   total=5374ms
cloud-hypervisor: boot=4411  exec=8    total=4447ms
fc-snapshot:      cold=5354  restore=80
```

## performance tips

### firecracker

- **`enable_pci: true`** -- virtio-pci with MSI-X interrupts instead of MMIO. better I/O throughput (>= 1.13)
- **`io_engine: "Async"`** -- io_uring for block I/O instead of blocking syscalls (host kernel >= 5.10.51)
- **`pmem_devices`** -- use virtio-pmem for read-only images like the nix store. bypasses the block layer entirely (>= 1.14)
- **snapshots** -- pre-built snapshot restore is ~6x faster than cold boot (25ms mmap vs full kernel boot)
- **cgroups v2** -- firecracker snapshot restore has high latency on cgroups v1. NixOS defaults to v2 but verify with `stat -fc %T /sys/fs/cgroup` (should show `cgroup2fs`)
- **huge pages** -- `huge_pages: "2M"` reduces TLB misses for memory-intensive guests

### cloud-hypervisor

- upgrades to v43+ automatically get VIRTIO_RING_F_INDIRECT_DESC and VIRTIO_BLK_F_SEG_MAX for better block throughput
- v51+ adds transparent huge pages for shared memory and DISCARD/WRITE_ZEROES for thin provisioning

## debugging

### verbose boot output

add `debug_boot: true` to your machine config (or pass it in the nix test) to
get full systemd debug output on the console:

```nix
nodes = {
  server = { ... }: {
    # attest config
  };
};
# in the nix make-test.nix call:
debugBoot = true;
```

when `wait_for_unit` or `wait_for_open_port` times out, attest automatically
logs failed systemd units and the last 30 journal lines.

### fetching logs from a running VM

```elixir
# in your test script
{:ok, logs} = Attest.journal(server)
{:ok, logs} = Attest.journal(server, unit: "headscale.service", lines: 50)
IO.puts(logs)
```

### interactive debugging

to poke around a hanging VM, change your test script to pause indefinitely:

```elixir
start_all.()
IO.puts("VMs started, drop into IEx to debug")
Process.sleep(:infinity)
```

then run with `--interactive`. from the IEx shell:

```elixir
# check what's stuck
{:ok, pid} = Attest.Driver.get_machine(driver, "server")
Attest.Machine.execute(pid, "systemctl list-jobs")
Attest.Machine.execute(pid, "journalctl -b --no-pager")
```

### common boot hang causes

- **`systemd-networkd-wait-online.service`** -- waiting for a network interface
  that doesn't exist in the VM. disable with
  `systemd.services.systemd-networkd-wait-online.enable = false`
- **DNS resolution** -- services blocking on DNS when no nameserver is reachable
- **missing kernel modules** -- check `dmesg` for errors

## development

```bash
mix test                    # unit tests (304 tests)
mix format                  # format
nix flake check --quiet     # full check: build, format, tests, integration
iex -S mix                  # repl
```

## architecture

see [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## licence

MIT
