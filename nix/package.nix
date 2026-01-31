# nixos-test package build using mixRelease
#
# usage:
#   packageSet = import ./package.nix { inherit pkgs beamPackages elixir; };
#   inherit (packageSet) nixos-test mixFodDeps;
{
  pkgs,
  beamPackages,
  elixir,
}:
let
  pname = "nixos-test";
  version = "0.1.0";
  src = ./..;

  erlang = beamPackages.erlang;

  # fetch mix dependencies as FOD (fixed-output derivation)
  # prod deps only (for release build)
  mixFodDeps = beamPackages.fetchMixDeps {
    inherit
      pname
      version
      src
      elixir
      ;
    hash = "sha256-T1uL3xXXmCkobJJhS3p6xMrJUyiim3AMwaG87/Ix7A8=";
  };

  # all deps including dev/test (for running tests)
  mixFodDepsAll = beamPackages.fetchMixDeps {
    pname = "${pname}-all-deps";
    inherit version src elixir;
    mixEnv = ""; # empty = all deps
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  # build the release
  nixos-test = beamPackages.mixRelease {
    inherit
      pname
      version
      src
      elixir
      mixFodDeps
      ;

    # build as escript for CLI usage
    postBuild = ''
      mix escript.build
    '';

    installPhase =
      let
        wrapper = pkgs.writeShellScript "nixos-test" ''
          exec ${erlang}/bin/escript @out@/libexec/nixos-test-escript "$@"
        '';
      in
      ''
        runHook preInstall
        mkdir -p $out/bin $out/libexec
        cp nixos_test $out/libexec/nixos-test-escript

        # create wrapper script
        substitute ${wrapper} $out/bin/nixos-test --subst-var out
        chmod +x $out/bin/nixos-test
        runHook postInstall
      '';

    meta = with pkgs.lib; {
      description = "NixOS test driver rewritten in Elixir";
      homepage = "https://github.com/anomalyco/nixos-test-ng";
      license = licenses.mit;
      mainProgram = "nixos-test";
    };
  };
in
{
  inherit nixos-test mixFodDeps;
}
