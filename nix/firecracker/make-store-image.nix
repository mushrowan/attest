# build a compressed erofs nix store image
#
# contains only the store closure needed for the NixOS system, plus
# nix-path-registration for first-boot DB import. much smaller than
# ext4 (typically ~350MB vs ~1.2GB) and faster to read (compressed,
# read-only, no journal overhead)
#
# usage:
#   storeImage = import ./make-store-image.nix {
#     inherit pkgs toplevel;
#   };
{
  pkgs,
  # the NixOS system.build.toplevel derivation
  toplevel,
}:
let
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
in
pkgs.runCommand "nix-store-image"
  {
    nativeBuildInputs = [
      pkgs.erofs-utils
      pkgs.gnutar
    ];
  }
  ''
    echo "creating erofs nix store image..."

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

    echo "erofs image: $(du -sh $out | cut -f1)"
  ''
