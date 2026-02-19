# attest package build
#
# uses mixRelease with escriptBinName, matching nixpkgs conventions
# (see ex_doc, protoc-gen-elixir for reference)
{
  beamPackages,
  fetchMixDeps ? beamPackages.fetchMixDeps,
  mixRelease ? beamPackages.mixRelease,
  lib,
}:
let
  pname = "attest";
  version = "0.1.0";
  src = ./..;
in
{
  attest = mixRelease {
    inherit pname version src;

    escriptBinName = "attest";

    mixFodDeps = fetchMixDeps {
      inherit src version;
      pname = "attest-deps";
      hash = "sha256-T1uL3xXXmCkobJJhS3p6xMrJUyiim3AMwaG87/Ix7A8=";
    };

    # all deps including dev/test (for running tests in nix)
    passthru.mixFodDepsAll = fetchMixDeps {
      inherit src version;
      pname = "attest-all-deps";
      mixEnv = "";
      hash = "sha256-DfZ0GtQInaK04JxgjarPtLsS1JHC288PNc9Idum3rW4=";
    };

    stripDebug = true;

    meta = {
      description = "NixOS test driver in elixir";
      license = lib.licenses.mit;
      mainProgram = "attest";
    };
  };
}
