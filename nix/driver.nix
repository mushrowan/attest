# wrap the elixir escript with VM start scripts, test script, and vlans
#
# mirrors what the python driver.nix does: collects start scripts from
# nodes, writes the test script to $out, wraps the binary with env vars
#
# usage:
#   driver = import ./driver.nix {
#     inherit pkgs;
#     nixos-test-ng = self'.packages.nixos-test;
#     nodes = { server = serverVM; client = clientVM; };
#     testScript = ''
#       start_all.()
#       server |> NixosTest.wait_for_unit("nginx.service")
#     '';
#     vlans = [ 1 ];
#   };
{
  pkgs,
  nixos-test-ng,
  # attrset of node name -> NixOS system.build.vm derivation
  nodes,
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

  # collect start scripts from VMs: /nix/store/.../bin/run-<name>-vm
  vmStartScripts = lib.concatStringsSep " " (
    lib.mapAttrsToList (_name: vm: "${vm}/bin/run-*-vm") nodes
  );

  vlansStr = lib.concatStringsSep " " (map toString vlans);
in
pkgs.runCommand "nixos-test-driver-${name}"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    passthru = {
      inherit nodes;
    };
    meta.mainProgram = "nixos-test-driver";
  }
  ''
        mkdir -p $out/bin

        # resolve start script globs
        vmStartScripts=($(for i in ${vmStartScripts}; do echo $i; done))

        # write test script
        cat > $out/test-script.exs <<'ELIXIR_SCRIPT'
    ${testScript}
    ELIXIR_SCRIPT

        # create wrapper
        makeWrapper ${nixos-test-ng}/bin/nixos-test $out/bin/nixos-test-driver \
          --set startScripts "''${vmStartScripts[*]}" \
          --set testScript "$out/test-script.exs" \
          --set globalTimeout "${toString globalTimeout}" \
          --set vlans '${vlansStr}' \
          ${lib.escapeShellArgs (
            lib.concatMap (arg: [
              "--add-flags"
              arg
            ]) extraDriverArgs
          )}
  ''
