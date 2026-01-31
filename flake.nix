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
          inherit (packageSet) nixos-test mixFodDeps;
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

            # mix test - run in the package build since it has deps set up
            test = nixos-test.overrideAttrs (old: {
              pname = "nixos-test-tests";

              # override to run tests instead of building
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
            });
          };

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
