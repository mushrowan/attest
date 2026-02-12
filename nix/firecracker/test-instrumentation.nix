# firecracker-specific test instrumentation
#
# replaces qemu's test-instrumentation.nix for firecracker VMs.
# uses vsock backdoor instead of virtconsole, configures the rootfs
# on /dev/vda, and registers nix store paths on first boot
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./vsock-backdoor.nix
  ];

  config = {
    # vsock backdoor replaces virtconsole shell
    testing.vsockBackdoor = true;

    # root filesystem — firecracker presents virtio-blk as /dev/vda
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };

    # no bootloader — firecracker boots kernel directly
    boot.loader.grub.enable = false;

    # initrd needs virtio drivers to mount /dev/vda
    # firecracker uses virtio_mmio (not PCI) for device transport
    boot.initrd.availableKernelModules = [
      "virtio_mmio"
      "virtio_blk"
      "ext4"
    ];

    # kernel params for serial console and crash behaviour
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

    # slow timeouts for test VMs (same as test-instrumentation.nix)
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
    # the ext4 rootfs includes /nix-path-registration from make-ext4-fs.nix
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
