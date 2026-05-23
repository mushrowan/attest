# development shell for attest
#
# usage:
#   devShells.default = import ./nix/devshell.nix { inherit pkgs elixir beamPackages checks; };
{
  pkgs,
  elixir,
  beamPackages,
  checks ? { },
}:
let
  mix2nix = pkgs.mix2nix.override { inherit beamPackages; };
in
pkgs.mkShell {
  buildInputs = [
    # elixir toolchain
    elixir
    # note: hex from nixpkgs has compatibility issues with elixir 1.17
    # use `mix local.hex --force` to install a working version
    beamPackages.rebar3
    mix2nix

    # for mix deps
    pkgs.git

    # VDE for inter-VM networking (VLANs)
    pkgs.vde2

    # OCR for screenshot text extraction
    pkgs.tesseract
    pkgs.imagemagick

    # useful tools
    pkgs.jq
    pkgs.curl
  ];

  packages = with pkgs; [
    # run all flake checks with verbose output
    (writeShellScriptBin "check-verbose" ''
      set -e
      echo "=== check-verbose: Build all flake checks with full logs ==="
      echo ""

      system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
      checks=$(nix eval ".#checks.$system" --apply 'builtins.attrNames' --json | ${jq}/bin/jq -r '.[]')

      for check in $checks; do
        echo "=== Building: $check ==="
        nix build ".#checks.$system.$check" \
          --no-link \
          --print-build-logs \
          "$@" || { echo "FAILED: $check"; exit 1; }
      done

      echo ""
      echo "=== All checks passed! ==="
    '')

    # quick test runner
    (writeShellScriptBin "t" ''
      mix test "$@"
    '')

    # format and check
    (writeShellScriptBin "fmt" ''
      mix format "$@"
    '')

    # update every pinned dependency source in this repo
    (writeShellScriptBin "nupd" ''
      set -euo pipefail

      export HEX_HOME="$PWD/.nix-hex"
      export MIX_HOME="$PWD/.nix-mix"
      export ERL_FLAGS="+fnu"

      rm -f "$HEX_HOME/cache.ets"

      echo "updating flake inputs..."
      nix flake update

      echo "updating hex dependencies..."
      mix deps.clean --unused
      mix deps.get
      mix deps.update --all
      mix deps.clean --unused
      mix deps.get

      echo "regenerating nix mix deps..."
      mix deps.nix
      nix fmt nix/mix-deps.nix

      echo "validating dependency update..."
      mix test
      nix build .#attest --no-link

      echo "changed files:"
      jj --color never st || true

      echo "dependency update complete"
    '')
  ];

  shellHook = ''
    # set up mix/hex home directories
    export MIX_HOME=$PWD/.nix-mix
    export HEX_HOME=$PWD/.nix-hex
    export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH

    # utf-8 for erlang
    export LANG=C.UTF-8

    # keep shell history in iex
    export ERL_AFLAGS="-kernel shell_history enabled"

    mkdir -p $MIX_HOME $HEX_HOME

    # install hex if not present (nixpkgs hex has elixir 1.17 compat issues)
    if [ ! -f "$MIX_HOME/archives/hex-"*"/hex/ebin/hex.app" ]; then
      echo "installing hex..."
      mix local.hex --force --if-missing
    fi

    echo "attest dev shell"
    echo ""
    echo "commands:"
    echo "  mix test         - run tests"
    echo "  mix format       - format code"
    echo "  mix credo        - run linter"
    echo "  mix dialyzer     - run type checker"
    echo "  iex -S mix       - interactive shell"
    echo "  check-verbose    - run all nix checks"
    echo "  nupd             - update flake, hex, and generated nix deps"
    echo "  nix build        - build the package"
    echo ""
  '';
}
