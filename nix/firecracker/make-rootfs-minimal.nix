# build a minimal ext4 rootfs for firecracker/cloud-hypervisor VMs
#
# contains ONLY the mutable directories NixOS needs (etc, var, tmp,
# root) plus nix-path-registration. the nix store itself is mounted
# separately via an erofs image on a second drive
#
# this produces a ~10MB image vs ~1.2GB for the full-closure rootfs
{
  pkgs,
  # the NixOS system.build.toplevel derivation
  toplevel,
  # name for the output derivation
  name ? "firecracker",
}:
let
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
in
pkgs.runCommand "rootfs-minimal-${name}"
  {
    nativeBuildInputs = [
      pkgs.e2fsprogs
      pkgs.fakeroot
    ];
  }
  ''
    # create a temp dir with the rootfs contents
    root=$TMPDIR/rootfs
    mkdir -p $root/{etc,tmp,var,root,run,proc,sys,dev}
    mkdir -p $root/nix/.ro-store
    mkdir -p $root/nix/.rw-store/{upper,work}
    mkdir -p $root/nix/store

    # copy nix-path-registration for first-boot store DB import
    cp ${closureInfo}/registration $root/nix-path-registration

    # create the ext4 image (small — just mutable state)
    # 64MB is plenty for the mutable dirs
    truncate -s 64M $out
    fakeroot mkfs.ext4 -q -L nixos -d $root $out
    tune2fs -c 0 -i 0 $out 2>/dev/null

    echo "minimal rootfs: $(du -sh $out | cut -f1)"
  ''
