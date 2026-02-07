# wrap the elixir escript with a JSON machine config, test script, and vlans
#
# generates a backend-agnostic JSON machine config file that the driver
# reads via --machine-config (or machineConfig env var). supports both
# QEMU and Firecracker backends
#
# usage:
#   driver = import ./driver.nix {
#     inherit pkgs;
#     nixos-test-ng = self'.packages.nixos-test;
#     machines = [
#       { name = "server"; backend = "qemu"; start_command = "${serverVM}/bin/run-server-vm"; }
#       { name = "client"; backend = "qemu"; start_command = "${clientVM}/bin/run-client-vm"; }
#     ];
#     testScript = ''
#       start_all.()
#       server |> NixosTest.wait_for_unit("nginx.service")
#     '';
#     vlans = [ 1 ];
#   };
{
  pkgs,
  nixos-test-ng,
  # list of machine config attrsets (see MachineConfig for schema)
  machines,
  # elixir test script string
  testScript,
  # list of VLAN numbers
  vlans ? [ ],
  # global timeout in seconds
  globalTimeout ? 3600,
  # extra CLI args
  extraDriverArgs ? [ ],
  # test name for the derivation
  name ? "nixos-test-ng",
}:
let
  inherit (pkgs) lib;

  # build the JSON machine config
  machineConfigJson = builtins.toJSON {
    inherit vlans;
    global_timeout = globalTimeout;
    inherit machines;
  };

  machineConfigFile = pkgs.writeText "machine-config-${name}.json" machineConfigJson;
in
pkgs.runCommand "nixos-test-driver-${name}"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru = {
      inherit machines;
    };
    meta.mainProgram = "nixos-test-driver";
  }
  ''
    mkdir -p $out/bin

    # write test script
    cat > $out/test-script.exs <<'ELIXIR_SCRIPT'
    ${testScript}
    ELIXIR_SCRIPT

    # create wrapper with JSON machine config
    makeWrapper ${nixos-test-ng}/bin/nixos-test $out/bin/nixos-test-driver \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.vde2 ]} \
      --set machineConfig "${machineConfigFile}" \
      --set testScript "$out/test-script.exs" \
      ${lib.escapeShellArgs (
        lib.concatMap (arg: [
          "--add-flags"
          arg
        ]) extraDriverArgs
      )}
  ''
