# minimal NixOS VM for integration testing
# includes test-instrumentation.nix for shell backdoor
{ pkgs }:
let
  nixos = import "${pkgs.path}/nixos" {
    system = pkgs.stdenv.hostPlatform.system;
    configuration = {
      imports = [
        "${pkgs.path}/nixos/modules/virtualisation/qemu-vm.nix"
        "${pkgs.path}/nixos/modules/testing/test-instrumentation.nix"
      ];

      # minimal memory for fast boot
      virtualisation.memorySize = 512;
      virtualisation.cores = 1;

      # reduce closure size
      documentation.enable = false;

      # required for qemu-vm module
      fileSystems."/" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "ext4";
      };
      boot.loader.grub.enable = false;
    };
  };
in
nixos.config.system.build.vm
