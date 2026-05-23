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
        nativeBuildInputs = [ pkgs.makeWrapper ];
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        set -euo pipefail

        export STATE_DIR=$(mktemp -d)
        export VM_SCRIPT="${vmScript}"
        export HOME=$TMPDIR
        export ERL_FLAGS="+fnu"

        makeWrapper ${attest}/bin/attest $TMPDIR/attest-driver \
          --set STATE_DIR "$STATE_DIR" \
          --set VM_SCRIPT "${vmScript}" \
          --set HOME "$HOME" \
          --set ERL_FLAGS "+fnu"

        $TMPDIR/attest-driver -o $out --test-script ${./run-test.exs}

        echo "attest timing integration: $(tr -d '\n' < "$out/timings.json")" >&2
      '';

  # multi-vm test: boot two VMs via Driver
  multi-vm =
    pkgs.runCommand "attest-multi-vm"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        set -euo pipefail

        export STATE_DIR=$(mktemp -d)
        export VM_SCRIPT="${vmScript}"
        export HOME=$TMPDIR
        export ERL_FLAGS="+fnu"

        makeWrapper ${attest}/bin/attest $TMPDIR/attest-driver \
          --set STATE_DIR "$STATE_DIR" \
          --set VM_SCRIPT "${vmScript}" \
          --set HOME "$HOME" \
          --set ERL_FLAGS "+fnu"

        $TMPDIR/attest-driver -o $out --test-script ${./multi-vm-test.exs}

        echo "attest timing integration-multi-vm: $(tr -d '\n' < "$out/timings.json")" >&2
      '';
in
# return basic test by default (for backwards compat with flake.nix)
basic // { inherit basic multi-vm; }
