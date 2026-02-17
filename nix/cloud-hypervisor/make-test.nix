# create a NixOS integration test using cloud-hypervisor VMs
#
# builds ext4 rootfs images and extracts vmlinux for each node,
# then runs the test via the elixir driver with backend=cloud-hypervisor.
# uses vsock for the shell backdoor (same as firecracker)
#
# supports splitStore mode (erofs nix store on second drive) for faster boot
{
  pkgs,
  attest,
  # test name
  name,
  # attrset of node name -> NixOS module (or list of modules)
  nodes,
  # elixir test script string
  testScript,
  # list of VLAN numbers
  vlans ? [ ],
  # global timeout in seconds
  globalTimeout ? 3600,
  # extra CLI args passed to the driver
  extraDriverArgs ? [ ],
  # default memory per VM in MiB
  memSize ? 256,
  # default vCPUs per VM
  vcpuCount ? 1,
  # use split store (erofs nix store on second drive)
  splitStore ? false,
}:
let
  inherit (pkgs) lib;

  # evaluate a NixOS config for cloud-hypervisor
  evalNode =
    nodeName: nodeConfig:
    let
      modules = if builtins.isList nodeConfig then nodeConfig else [ nodeConfig ];

      nixos = import "${pkgs.path}/nixos" {
        system = pkgs.stdenv.hostPlatform.system;
        configuration = {
          imports = modules ++ [
            # reuse firecracker's test-instrumentation (same vsock + rootfs approach)
            # but with virtio_pci instead of virtio_mmio
            ../firecracker/test-instrumentation.nix
            {
              # override: cloud-hypervisor uses PCI, not MMIO
              boot.initrd.availableKernelModules = lib.mkForce (
                [
                  "virtio_pci"
                  "virtio_blk"
                  "ext4"
                ]
                ++ lib.optionals splitStore [
                  "erofs"
                  "overlay"
                ]
              );
              testing.splitStoreImage = splitStore;
            }
          ];

          networking.hostName = lib.mkDefault nodeName;
        };
      };

      toplevel = nixos.config.system.build.toplevel;
      vmlinux = "${nixos.config.boot.kernelPackages.kernel.dev}/vmlinux";
      initrd = "${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile}";
      bootArgs = builtins.concatStringsSep " " (
        nixos.config.boot.kernelParams ++ [ "init=${toplevel}/init" ]
      );

      rootfs =
        if splitStore then
          import ../firecracker/make-rootfs-minimal.nix {
            inherit pkgs toplevel;
            inherit name;
          }
        else
          import ../firecracker/make-rootfs.nix {
            inherit pkgs toplevel;
            inherit name;
          };

      storeImage = lib.optionalAttrs splitStore {
        store = import ../firecracker/make-store-image.nix {
          inherit pkgs toplevel;
        };
      };
    in
    {
      config = nixos.config;
      inherit
        toplevel
        vmlinux
        initrd
        bootArgs
        rootfs
        ;
    }
    // storeImage;

  evaluatedNodes = lib.mapAttrs evalNode nodes;

  machines = lib.mapAttrsToList (
    nodeName: node:
    {
      name = nodeName;
      backend = "cloud-hypervisor";
      cloud_hypervisor_bin = "${pkgs.cloud-hypervisor}/bin/cloud-hypervisor";
      kernel_image_path = node.vmlinux;
      initrd_path = node.initrd;
      rootfs_path = "${node.rootfs}";
      kernel_boot_args = node.bootArgs;
      mem_size_mib = memSize;
      vcpu_count = vcpuCount;
    }
    // lib.optionalAttrs splitStore {
      store_image_path = "${node.store}";
    }
  ) evaluatedNodes;

  rootfsImages = lib.mapAttrs (_: node: node.rootfs) evaluatedNodes;

  driver = import ../driver.nix {
    inherit
      pkgs
      attest
      vlans
      globalTimeout
      extraDriverArgs
      name
      machines
      ;
    inherit testScript;
  };

  test = import ../run.nix {
    inherit pkgs driver name;
  };
in
test
// {
  inherit driver;
  inherit rootfsImages;
}
