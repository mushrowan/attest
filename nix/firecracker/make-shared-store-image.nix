# build a single erofs nix store image containing the union of multiple
# NixOS system closures
#
# when a test has multiple nodes that share most of their store paths
# (common in multi-VM tests), a shared image avoids duplicating ~1.8GB
# per node in the nix sandbox closure
#
# usage:
#   sharedStore = import ./make-shared-store-image.nix {
#     inherit pkgs;
#     toplevels = [ node1.toplevel node2.toplevel ... ];
#   };
{
  pkgs,
  # list of NixOS system.build.toplevel derivations
  toplevels,
}:
let
  closureInfo = pkgs.closureInfo { rootPaths = toplevels; };
in
pkgs.runCommand "nix-store-image"
  {
    nativeBuildInputs = [
      pkgs.erofs-utils
      pkgs.gnutar
    ];
  }
  ''
    echo "creating shared erofs nix store image for ${toString (builtins.length toplevels)} systems..."

    tar --create \
      --absolute-names \
      --verbatim-files-from \
      --transform 'flags=rSh;s|/nix/store/||' \
      --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' \
      --files-from ${closureInfo}/store-paths \
      | mkfs.erofs \
        --quiet \
        --force-uid=0 \
        --force-gid=0 \
        -L nix-store \
        -U eb176051-bd15-49b7-9e6b-462e0b467019 \
        -T 0 \
        --hard-dereference \
        --tar=f \
        "$out"

    echo "shared erofs image: $(du -sh $out | cut -f1)"
  ''
