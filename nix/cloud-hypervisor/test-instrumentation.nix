# cloud-hypervisor-specific test instrumentation
#
# reuses the vsock backdoor from firecracker (both use virtio-vsock).
# configures rootfs on /dev/vda via virtio-pci (cloud-hypervisor uses
# PCI transport, not MMIO like firecracker)
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../firecracker/vsock-backdoor.nix
  ];

  config = {
    # vsock backdoor for the shell transport
    testing.vsockBackdoor = true;

    # root filesystem — cloud-hypervisor presents virtio-blk as /dev/vda
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };

    # no bootloader — cloud-hypervisor boots kernel directly (PVH)
    boot.loader.grub.enable = false;

    # initrd needs virtio drivers to mount /dev/vda
    # cloud-hypervisor uses virtio over PCI (not MMIO)
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "ext4"
    ];

    # kernel params — use serial for console output
    boot.kernelParams = [
      "console=ttyS0"
      "panic=1"
      "boot.panic_on_fail"
    ];

    boot.consoleLogLevel = 7;

    # match test-instrumentation.nix sysctl settings
    boot.kernel.sysctl = {
      "kernel.hung_task_timeout_secs" = 600;
      "vm.panic_on_oom" = lib.mkDefault 2;
    };

    # slow timeouts for test VMs
    systemd.settings.Manager = {
      ShowStatus = false;
      DefaultTimeoutStartSec = 300;
      DefaultDeviceTimeoutSec = 300;
    };

    systemd.user.extraConfig = ''
      DefaultTimeoutStartSec=300
      DefaultDeviceTimeoutSec=300
    '';

    # register nix store paths on first boot
    boot.postBootCommands = lib.mkIf config.nix.enable ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
        rm /nix-path-registration
      fi
    '';

    # prevent internet access in tests
    networking.defaultGateway = lib.mkOverride 150 null;
    networking.nameservers = lib.mkOverride 150 [ ];

    # easy root login
    users.users.root.hashedPasswordFile = lib.mkOverride 150 "${pkgs.writeText "hashed-password.root" ""}";

    # minimal config
    documentation.enable = false;

    # no log rotation in tests
    services.logrotate.enable = lib.mkOverride 150 false;

    # stable state version
    system.stateVersion = lib.mkOverride 1200 lib.trivial.release;

    # predictable interface names
    networking.usePredictableInterfaceNames = false;
  };
}
