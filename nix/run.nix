# execute a wrapped test driver in a nix build sandbox
#
# this is the equivalent of the python run.nix's rawTestDerivation:
# it runs the driver binary, which boots VMs, runs the test script,
# and exits
#
# usage:
#   test = import ./run.nix {
#     inherit pkgs;
#     driver = import ./driver.nix { ... };
#     name = "my-test";
#   };
{
  pkgs,
  # the wrapped driver from driver.nix
  driver,
  # test name
  name ? "attest",
}:
pkgs.runCommand "vm-test-run-${name}"
  {
    requiredSystemFeatures = [
      "nixos-test"
      "kvm"
    ];
    meta.mainProgram = "attest-driver";
    passthru = {
      inherit driver;
    };
  }
  ''
    mkdir -p $out
    export HOME=$TMPDIR

    ${driver}/bin/attest-driver -o $out
  ''
