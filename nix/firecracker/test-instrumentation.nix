# firecracker-specific test instrumentation
#
# replaces qemu's test-instrumentation.nix for firecracker VMs.
# uses vsock backdoor instead of virtconsole, configures the rootfs
# on /dev/vda, and registers nix store paths on first boot.
#
# supports two modes:
# - full rootfs: entire closure in ext4 on /dev/vda (simple, slow)
# - split store: minimal ext4 on /dev/vda + erofs nix store on /dev/vdb (fast)
#   set testing.splitStoreImage = true to enable
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

  options.testing = {
    splitStoreImage = lib.mkEnableOption "split nix store image on /dev/vdb" // {
      default = false;
    };

    nodeNumber = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "node number for IP assignment (192.168.1.{nodeNumber})";
    };

    vlans = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ ];
      description = "VLAN numbers this node is attached to";
    };

    hostsEntries = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "extra /etc/hosts entries for inter-VM name resolution";
    };
  };

  config = {
    # vsock backdoor replaces virtconsole shell
    testing.vsockBackdoor = true;

    # root filesystem — firecracker presents virtio-blk as /dev/vda
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };

    # erofs nix store on second drive, with overlay for writability
    fileSystems."/nix/.ro-store" = lib.mkIf config.testing.splitStoreImage {
      device = "/dev/vdb";
      fsType = "erofs";
      options = [ "ro" ];
      neededForBoot = true;
    };

    fileSystems."/nix/store" = lib.mkIf config.testing.splitStoreImage {
      overlay = {
        lowerdir = [ "/nix/.ro-store" ];
        upperdir = "/nix/.rw-store/upper";
        workdir = "/nix/.rw-store/work";
      };
      neededForBoot = true;
    };

    # no bootloader — firecracker boots kernel directly
    boot.loader.grub.enable = false;

    # initrd needs virtio drivers to mount /dev/vda (and /dev/vdb for erofs)
    # firecracker uses virtio_mmio (not PCI) for device transport
    boot.initrd.availableKernelModules = [
      "virtio_mmio"
      "virtio_blk"
      "ext4"
    ]
    ++ lib.optionals config.testing.splitStoreImage [
      "erofs"
      "overlay"
    ]
    ++ lib.optionals (config.testing.vlans != [ ]) [
      "virtio_net"
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
    boot.postBootCommands = lib.mkIf config.nix.enable ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
        rm /nix-path-registration
      fi
    '';

    # disable dhcpcd — we use static IPs (dhcpcd waits 30s with no DHCP server)
    networking.useDHCP = false;

    # static IP per VLAN: 192.168.{vlan}.{nodeNumber}/24
    networking.interfaces = lib.mkIf (config.testing.vlans != [ ]) (
      lib.listToAttrs (
        lib.imap0 (
          idx: vlan:
          lib.nameValuePair "eth${toString idx}" {
            ipv4.addresses = [
              {
                address = "192.168.${toString vlan}.${toString config.testing.nodeNumber}";
                prefixLength = 24;
              }
            ];
          }
        ) config.testing.vlans
      )
    );

    # hostname resolution for all nodes
    networking.extraHosts = lib.mkIf (config.testing.hostsEntries != "") config.testing.hostsEntries;

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
