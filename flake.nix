{
  description = "attest — NixOS test driver in elixir";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          lib,
          ...
        }:
        let
          # headless erlang (no wx/gtk/webkitgtk, saves ~200MB closure)
          erlang = (pkgs.beam.override { wxSupport = false; }).interpreters.erlang_27;
          beamPackages = pkgs.beam.packagesWith erlang;
          elixir = beamPackages.elixir_1_17;

          # import package build
          packageSet = import ./nix/package.nix {
            inherit beamPackages;
            lib = pkgs.lib;
          };
          inherit (packageSet) attest;
        in
        {
          checks = {
            inherit attest;

            # mix format check
            format =
              pkgs.runCommand "mix-format-check"
                {
                  nativeBuildInputs = [ elixir ];
                  src = ./.;
                }
                ''
                  cd $src
                  export MIX_HOME=$TMPDIR/.mix
                  export HEX_HOME=$TMPDIR/.hex
                  mix format --check-formatted
                  touch $out
                '';

            # mix test - use all deps (including test deps)
            test = beamPackages.mixRelease {
              pname = "attest-tests";
              version = "0.1.0";
              src = ./.;
              mixFodDeps = attest.passthru.mixFodDepsAll;
              nativeBuildInputs = [
                pkgs.vde2
                pkgs.tesseract
                pkgs.imagemagick
              ];

              buildPhase = ''
                runHook preBuild
                MIX_ENV=test mix compile --no-deps-check
                runHook postBuild
              '';

              checkPhase = ''
                MIX_ENV=test mix test
              '';

              doCheck = true;

              installPhase = ''
                touch $out
              '';
            };
          }
          // lib.optionalAttrs pkgs.stdenv.isLinux (
            let
              integrationTests = import ./integration-tests {
                inherit pkgs;
                attest = attest;
              };
            in
            {
              # single-vm integration test (boot, execute, screenshot, shutdown)
              integration = integrationTests.basic;
              # multi-vm integration test (two VMs via Driver)
              integration-multi-vm = integrationTests.multi-vm;
              # make-test smoke test (nix wrapper end-to-end)
              make-test-smoke = import ./nix/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "smoke";
                nodes = {
                  machine = { };
                };
                testScript = ''
                  start_all.()
                  Attest.wait_for_unit(machine, "multi-user.target")
                  output = Attest.succeed(machine, "echo hello-from-make-test")

                  unless String.contains?(output, "hello-from-make-test") do
                    raise "unexpected output: #{inspect(output)}"
                  end
                '';
              };
              # multi-node make-test (two VMs, validates multi-node pipeline)
              make-test-multi = import ./nix/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "multi";
                nodes = {
                  server = { };
                  client = { };
                };
                testScript = ''
                  start_all.()
                  Attest.wait_for_unit(server, "multi-user.target")
                  Attest.wait_for_unit(client, "multi-user.target")

                  server_out = Attest.succeed(server, "hostname")
                  client_out = Attest.succeed(client, "hostname")

                  unless String.contains?(server_out, "server") do
                    raise "server hostname mismatch: #{inspect(server_out)}"
                  end

                  unless String.contains?(client_out, "client") do
                    raise "client hostname mismatch: #{inspect(client_out)}"
                  end
                '';
              };
              # firecracker make-test smoke test (ext4 rootfs, vmlinux, vsock backdoor)
              firecracker-smoke = import ./nix/firecracker/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "fc-smoke";
                nodes = {
                  machine = { };
                };
                testScript = ''
                  start_all.()
                  Attest.wait_for_unit(machine, "multi-user.target")
                  output = Attest.succeed(machine, "echo hello-from-firecracker")

                  unless String.contains?(output, "hello-from-firecracker") do
                    raise "unexpected output: #{inspect(output)}"
                  end
                '';
              };
              # TODO: vsock UDS not connectable after snapshot restore
              # (FC single-connection UDS + guest vsock reset race)
              # firecracker-snapshot = ...;
              # firecracker split-store smoke test (erofs nix store + minimal rootfs)
              firecracker-split = import ./nix/firecracker/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "fc-split";
                splitStore = true;
                nodes = {
                  machine = { };
                };
                testScript = ''
                  start_all.()
                  Attest.wait_for_unit(machine, "multi-user.target")
                  output = Attest.succeed(machine, "echo hello-from-split-store")

                  unless String.contains?(output, "hello-from-split-store") do
                    raise "unexpected output: #{inspect(output)}"
                  end

                  # verify nix store is an overlay mount
                  mount_out = Attest.succeed(machine, "mount | grep '/nix/store'")

                  unless String.contains?(mount_out, "overlay") do
                    raise "nix store not overlay-mounted: #{inspect(mount_out)}"
                  end
                '';
              };
              # firecracker multi-VM networking test (bridge + TAP)
              firecracker-network = import ./nix/firecracker/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "fc-net";
                splitStore = true;
                enableNetwork = true;
                nodes = {
                  alice =
                    { pkgs, ... }:
                    {
                      environment.systemPackages = [ pkgs.iputils ];
                    };
                  bob =
                    { pkgs, ... }:
                    {
                      environment.systemPackages = [ pkgs.iputils ];
                    };
                };
                testScript = ''
                  start_all.()

                  # verify both VMs have IPs
                  alice_ip = Attest.succeed(alice, "ip -4 addr show eth0 | grep inet")
                  IO.puts("alice: #{String.trim(alice_ip)}")
                  unless String.contains?(alice_ip, "192.168.1.1"), do: raise("alice should be .1")

                  bob_ip = Attest.succeed(bob, "ip -4 addr show eth0 | grep inet")
                  IO.puts("bob: #{String.trim(bob_ip)}")
                  unless String.contains?(bob_ip, "192.168.1.2"), do: raise("bob should be .2")

                  # ping each other
                  Attest.succeed(alice, "ping -c 1 -W 3 192.168.1.2")
                  IO.puts("alice -> bob: ok")
                  Attest.succeed(bob, "ping -c 1 -W 3 192.168.1.1")
                  IO.puts("bob -> alice: ok")

                  # hostname resolution via /etc/hosts
                  Attest.succeed(alice, "ping -c 1 -W 3 bob")
                  IO.puts("alice -> bob (hostname): ok")
                  Attest.succeed(bob, "ping -c 1 -W 3 alice")
                  IO.puts("bob -> alice (hostname): ok")

                  IO.puts("network test passed!")
                '';
              };
              # cloud-hypervisor make-test smoke test (ext4 rootfs, vmlinux, vsock)
              cloud-hypervisor-smoke = import ./nix/cloud-hypervisor/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "ch-smoke";
                nodes = {
                  machine = { };
                };
                testScript = ''
                  start_all.()
                  Attest.wait_for_unit(machine, "multi-user.target")
                  output = Attest.succeed(machine, "echo hello-from-cloud-hypervisor")

                  unless String.contains?(output, "hello-from-cloud-hypervisor") do
                    raise "unexpected output: #{inspect(output)}"
                  end
                '';
              };
              # cloud-hypervisor multi-VM networking test (bridge + TAP)
              cloud-hypervisor-network = import ./nix/cloud-hypervisor/make-test.nix {
                inherit pkgs;
                attest = attest;
                name = "ch-net";
                splitStore = true;
                enableNetwork = true;
                nodes = {
                  alice =
                    { pkgs, ... }:
                    {
                      environment.systemPackages = [ pkgs.iputils ];
                    };
                  bob =
                    { pkgs, ... }:
                    {
                      environment.systemPackages = [ pkgs.iputils ];
                    };
                };
                testScript = ''
                  start_all.()

                  alice_ip = Attest.succeed(alice, "ip -4 addr show eth0 | grep inet")
                  IO.puts("alice: #{String.trim(alice_ip)}")
                  unless String.contains?(alice_ip, "192.168.1.1"), do: raise("alice should be .1")

                  bob_ip = Attest.succeed(bob, "ip -4 addr show eth0 | grep inet")
                  IO.puts("bob: #{String.trim(bob_ip)}")
                  unless String.contains?(bob_ip, "192.168.1.2"), do: raise("bob should be .2")

                  Attest.succeed(alice, "ping -c 1 -W 3 192.168.1.2")
                  IO.puts("alice -> bob: ok")
                  Attest.succeed(bob, "ping -c 1 -W 3 192.168.1.1")
                  IO.puts("bob -> alice: ok")

                  Attest.succeed(alice, "ping -c 1 -W 3 bob")
                  IO.puts("alice -> bob (hostname): ok")
                  Attest.succeed(bob, "ping -c 1 -W 3 alice")
                  IO.puts("bob -> alice (hostname): ok")

                  IO.puts("ch network test passed!")
                '';
              };
            }
          );

          packages = {
            default = attest;
            inherit attest;
          }
          // lib.optionalAttrs pkgs.stdenv.isLinux {
            bench = import ./nix/bench.nix {
              inherit pkgs attest;
            };
          };

          devShells.default = import ./nix/devshell.nix {
            inherit pkgs elixir beamPackages;
            checks = self'.checks;
          };

          # treefmt configuration
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
            };
            settings.formatter = {
              # custom mix format wrapper
              mix-format = {
                command = pkgs.writeShellApplication {
                  name = "mix-format";
                  runtimeInputs = [ elixir ];
                  text = ''
                    export MIX_HOME="''${TMPDIR:-/tmp}/.mix"
                    export HEX_HOME="''${TMPDIR:-/tmp}/.hex"
                    mix format "$@"
                  '';
                };
                includes = [
                  "*.ex"
                  "*.exs"
                ];
              };
            };
          };
        };

      flake = {
        # nixos module for running tests (future)
        # nixosModules.default = ./nix/module.nix;
      };
    };
}
