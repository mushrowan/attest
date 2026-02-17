# integration test derivations
# runs elixir tests against real NixOS VMs
{
  pkgs,
  attest,
}:
let
  vm = import ./vm.nix { inherit pkgs; };
  vmScript = "${vm}/bin/run-nixos-vm";

  # single-vm test: boot, execute, screenshot, shutdown
  basic =
    pkgs.runCommand "attest-integration"
      {
        nativeBuildInputs = [ attest ];
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        set -euo pipefail

        export STATE_DIR=$(mktemp -d)
        export VM_SCRIPT="${vmScript}"
        export HOME=$TMPDIR

        echo "=== attest integration test ==="
        echo "VM script: $VM_SCRIPT"
        echo "State dir: $STATE_DIR"
        echo ""

        ${attest}/bin/attest eval-file ${./run-test.exs}

        echo ""
        echo "=== integration test passed ==="
        touch $out
      '';

  # multi-vm test: boot two VMs via Driver
  multi-vm =
    pkgs.runCommand "attest-multi-vm"
      {
        nativeBuildInputs = [ attest ];
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        set -euo pipefail

        export STATE_DIR=$(mktemp -d)
        export VM_SCRIPT="${vmScript}"
        export HOME=$TMPDIR

        echo "=== attest multi-vm test ==="
        echo "VM script: $VM_SCRIPT"
        echo "State dir: $STATE_DIR"
        echo ""

        ${attest}/bin/attest eval-file ${./multi-vm-test.exs}

        echo ""
        echo "=== multi-vm test passed ==="
        touch $out
      '';
in
# return basic test by default (for backwards compat with flake.nix)
basic // { inherit basic multi-vm; }
