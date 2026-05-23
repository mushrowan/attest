# attest package build
#
# uses mixRelease with escriptBinName, matching nixpkgs conventions
# (see ex_doc, protoc-gen-elixir for reference)
{
  beamPackages,
  mixRelease ? beamPackages.mixRelease,
  lib,
}:
let
  pname = "attest";
  version = "0.1.0";
  src = ./..;
  allMixNixDeps = import ./mix-deps.nix { inherit lib beamPackages; };
  prodMixNixDeps = lib.getAttrs [ "jason" ] allMixNixDeps;
  testMixNixDeps = lib.getAttrs [
    "castore"
    "excoveralls"
    "jason"
  ] allMixNixDeps;
in
{
  attest = mixRelease {
    inherit pname version src;

    escriptBinName = "attest";

    mixNixDeps = prodMixNixDeps;

    passthru.mixNixDeps = prodMixNixDeps;
    passthru.testMixNixDeps = testMixNixDeps;
    passthru.allMixNixDeps = allMixNixDeps;

    stripDebug = true;

    meta = {
      description = "NixOS test driver in elixir";
      license = lib.licenses.mit;
      mainProgram = "attest";
    };
  };
}
