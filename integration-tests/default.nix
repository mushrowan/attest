# integration test derivation
# runs the elixir test against a real NixOS VM
{
  pkgs,
  nixos-test-ng,
}:
let
  vm = import ./vm.nix { inherit pkgs; };
  vmScript = "${vm}/bin/run-nixos-vm";
  testScript = ./run-test.exs;
in
pkgs.runCommand "nixos-test-ng-integration"
  {
    nativeBuildInputs = [ nixos-test-ng ];

    # requires KVM for reasonable performance
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail

    export STATE_DIR=$(mktemp -d)
    export VM_SCRIPT="${vmScript}"
    export HOME=$TMPDIR

    echo "=== nixos-test-ng integration test ==="
    echo "VM script: $VM_SCRIPT"
    echo "State dir: $STATE_DIR"
    echo ""

    # run the elixir test script
    ${nixos-test-ng}/bin/nixos-test eval-file ${testScript}

    echo ""
    echo "=== integration test passed ==="
    touch $out
  ''
