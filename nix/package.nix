# attest package build using mixRelease
#
# usage:
#   packageSet = import ./package.nix { inherit pkgs beamPackages elixir; };
#   inherit (packageSet) attest mixFodDeps;
{
  pkgs,
  beamPackages,
  elixir,
}:
let
  pname = "attest";
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
    hash = "sha256-DfZ0GtQInaK04JxgjarPtLsS1JHC288PNc9Idum3rW4=";
  };

  # build the release
  attest = beamPackages.mixRelease {
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
        wrapper = pkgs.writeShellScript "attest" ''
          exec ${erlang}/bin/escript @out@/libexec/attest-escript "$@"
        '';
      in
      ''
        runHook preInstall
        mkdir -p $out/bin $out/libexec
        cp attest $out/libexec/attest-escript

        # create wrapper script
        substitute ${wrapper} $out/bin/attest --subst-var out
        chmod +x $out/bin/attest
        runHook postInstall
      '';

    meta = with pkgs.lib; {
      description = "NixOS test driver rewritten in Elixir";
      homepage = "https://github.com/anomalyco/attest";
      license = licenses.mit;
      mainProgram = "attest";
    };
  };
in
{
  inherit attest mixFodDeps mixFodDepsAll;
}
