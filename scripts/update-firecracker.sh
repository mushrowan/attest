#!/usr/bin/env bash
# update the firecracker fork flake input and cargo hash
#
# usage: ./scripts/update-firecracker.sh
#
# 1. updates the flake input to latest commit on the fork branch
# 2. sets cargoHash to fakeHash
# 3. builds to get the real hash
# 4. patches flake.nix with the correct hash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ updating firecracker-src flake input"
nix flake update firecracker-src

echo "→ setting cargo hash to fakeHash to trigger re-fetch"
sed -i 's|hash = "sha256-[^"]*";|hash = lib.fakeHash;|' flake.nix
git add flake.nix flake.lock

echo "→ building to discover new cargo hash (this fetches deps)"
got=$(nix build .#checks.x86_64-linux.firecracker-snapshot 2>&1 \
  | grep "got:" | head -1 | awk '{print $2}') || true

if [[ -z "$got" ]]; then
  echo "✗ couldn't extract hash — check build output"
  exit 1
fi

echo "→ got: $got"
sed -i "s|hash = lib.fakeHash;|hash = \"$got\";|" flake.nix

echo "→ verifying build"
git add flake.nix
nix build .#checks.x86_64-linux.firecracker-snapshot --no-link -L 2>&1 | tail -3

echo "✓ firecracker updated"
