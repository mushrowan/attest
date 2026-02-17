# execute a wrapped test driver in a nix build sandbox
#
# runs the driver binary, which boots VMs, runs the test script, and exits
#
# when networking is enabled (preScript != ""), the build runs in a
# user+network namespace so we can create bridges and TAP devices for
# inter-VM communication. requires /dev/net/tun in the sandbox:
#
#   nix.settings.extra-sandbox-paths = [ "/dev/net/tun" ];
#
{
  pkgs,
  # the wrapped driver from driver.nix
  driver,
  # test name
  name ? "attest",
  # script to run before the driver (eg bridge+TAP setup)
  preScript ? "",
}:
let
  hasNetwork = preScript != "";

  # when networking is needed, run inside a user+network namespace
  # so we can create bridges and TAP devices without root
  wrapCmd =
    if hasNetwork then
      "${pkgs.util-linux}/bin/unshare --user --map-root-user --net ${pkgs.bash}/bin/bash -e"
    else
      "${pkgs.bash}/bin/bash -e";
in
pkgs.runCommand "vm-test-run-${name}"
  {
    requiredSystemFeatures = [
      "nixos-test"
      "kvm"
    ];
    nativeBuildInputs = pkgs.lib.optionals hasNetwork [ pkgs.iproute2 ];
    meta.mainProgram = "attest-driver";
    passthru = {
      inherit driver;
    };
  }
  ''
    mkdir -p $out
    export HOME=$TMPDIR

    ${wrapCmd} <<'INNER_SCRIPT'
    ${pkgs.lib.optionalString hasNetwork ''
    ip link set lo up
    ''}

    ${preScript}

    ${driver}/bin/attest-driver -o $out
    INNER_SCRIPT
  ''
