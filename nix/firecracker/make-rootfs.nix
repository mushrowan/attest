# build an ext4 rootfs image for a firecracker VM
#
# wraps nixpkgs' make-ext4-fs.nix to produce a rootfs containing the
# full NixOS system closure. the image includes nix-path-registration
# for first-boot store path registration (see test-instrumentation.nix)
#
# usage:
#   rootfs = import ./make-rootfs.nix {
#     inherit pkgs;
#     toplevel = config.system.build.toplevel;
#     name = "server";
#   };
{
  pkgs,
  # the NixOS system.build.toplevel derivation
  toplevel,
  # name for the output derivation
  name ? "firecracker",
}:

pkgs.callPackage "${pkgs.path}/nixos/lib/make-ext4-fs.nix" {
  storePaths = [ toplevel ];
  volumeLabel = "nixos";

  # make-ext4-fs.nix copies the store closure and includes
  # nix-path-registration automatically. we just need basic dirs
  # that NixOS activation expects to exist on the rootfs
  populateImageCommands = ''
    mkdir -p ./files/etc
    mkdir -p ./files/tmp
    mkdir -p ./files/var
    mkdir -p ./files/root
  '';
}
