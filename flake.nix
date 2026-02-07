{
  description = "nixos test driver rewritten in elixir";

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
          # use latest erlang and elixir
          erlang = pkgs.beam.interpreters.erlang_27;
          beamPackages = pkgs.beam.packagesWith erlang;
          elixir = beamPackages.elixir_1_17;

          # import package build
          packageSet = import ./nix/package.nix {
            inherit pkgs beamPackages elixir;
          };
          inherit (packageSet) nixos-test mixFodDeps mixFodDepsAll;
        in
        {
          checks = {
            inherit nixos-test;

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
              pname = "nixos-test-tests";
              version = "0.1.0";
              src = ./.;
              inherit elixir;
              mixFodDeps = mixFodDepsAll;
              nativeBuildInputs = [ pkgs.vde2 ];

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
                nixos-test-ng = nixos-test;
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
                nixos-test-ng = nixos-test;
                name = "smoke";
                nodes = {
                  machine = { };
                };
                testScript = ''
                  start_all.()
                  NixosTest.wait_for_unit(machine, "multi-user.target")
                  output = NixosTest.succeed(machine, "echo hello-from-make-test")

                  unless String.contains?(output, "hello-from-make-test") do
                    raise "unexpected output: #{inspect(output)}"
                  end
                '';
              };
            }
          );

          packages = {
            default = nixos-test;
            inherit nixos-test;
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
