# attest

NixOS integration test driver in elixir. OTP supervision trees for VM lifecycle,
pluggable backends (QEMU, firecracker, cloud-hypervisor), elixir test scripts
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
| firecracker | ~5s | TAP + bridge | no | yes (~85ms restore) |
| cloud-hypervisor | ~4.5s | TAP + bridge | no | yes |

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
tests with networking - single-VM tests work without it.

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

```elixir
# boot
start_all.()

# shell commands
Attest.succeed(machine, "command")           # run, raise on non-zero exit
Attest.fail(machine, "command")              # run, raise on zero exit
{code, output} = Attest.Machine.execute(machine, "command")

# wait for state
Attest.wait_for_unit(machine, "nginx.service")
Attest.wait_for_open_port(machine, 80)

# shutdown
Attest.Machine.shutdown(machine)

# snapshots (firecracker only)
Attest.snapshot_create(machine, "/tmp/snap")
Attest.snapshot_restore(machine, "/tmp/snap")

# screenshots (QEMU only)
Attest.Machine.screenshot(machine, "/tmp/screen.ppm")

# OCR (QEMU only, needs tesseract)
Attest.Machine.get_screen_text(machine)
Attest.Machine.wait_for_text(machine, "login:", timeout: 30_000)
```

## benchmarks

run `nix build .#bench -L` to compare backends:

```
qemu:             boot=7949  exec=62   total=11160ms
firecracker:      boot=5168  exec=12   total=5374ms
cloud-hypervisor: boot=4411  exec=8    total=4447ms
fc-snapshot:      cold=5354  restore=80
```

## development

```bash
mix test                    # unit tests (225 tests)
mix format                  # format
nix flake check --quiet     # full check: build, format, tests, integration
iex -S mix                  # repl
```

## architecture

see [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## licence

MIT
