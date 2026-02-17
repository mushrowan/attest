# create a NixOS integration test using firecracker VMs
#
# builds ext4 rootfs images and extracts vmlinux for each node,
# then runs the test via the elixir driver with backend=firecracker
#
# usage:
#   test = import ./make-test.nix {
#     inherit pkgs attest;
#     name = "my-test";
#     nodes = {
#       server = { pkgs, ... }: {
#         services.nginx.enable = true;
#       };
#     };
#     testScript = ''
#       start_all.()
#       server |> Attest.wait_for_unit("nginx.service")
#     '';
#   };
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
}:
let
  inherit (pkgs) lib;

  # evaluate a NixOS config for firecracker
  evalNode =
    nodeName: nodeConfig:
    let
      modules = if builtins.isList nodeConfig then nodeConfig else [ nodeConfig ];

      nixos = import "${pkgs.path}/nixos" {
        system = pkgs.stdenv.hostPlatform.system;
        configuration = {
          imports = modules ++ [
            ./test-instrumentation.nix
          ];

          # set hostname to node name
          networking.hostName = lib.mkDefault nodeName;
        };
      };

      toplevel = nixos.config.system.build.toplevel;

      # vmlinux (uncompressed kernel) lives in the .dev output
      vmlinux = "${nixos.config.boot.kernelPackages.kernel.dev}/vmlinux";

      # initrd for proper NixOS boot (mounts /dev/vda, switch-root)
      initrd = "${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile}";

      # build kernel boot args from NixOS config + init path
      bootArgs = builtins.concatStringsSep " " (
        nixos.config.boot.kernelParams
        ++ [
          "init=${toplevel}/init"
        ]
      );

      # build ext4 rootfs image
      rootfs = import ./make-rootfs.nix {
        inherit pkgs toplevel;
        inherit name;
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
    };

  # evaluate all nodes
  evaluatedNodes = lib.mapAttrs evalNode nodes;

  # build machine config list for the driver
  machines = lib.mapAttrsToList (nodeName: node: {
    name = nodeName;
    backend = "firecracker";
    firecracker_bin = "${pkgs.firecracker}/bin/firecracker";
    kernel_image_path = node.vmlinux;
    initrd_path = node.initrd;
    rootfs_path = "${node.rootfs}";
    kernel_boot_args = node.bootArgs;
    mem_size_mib = memSize;
    vcpu_count = vcpuCount;
  }) evaluatedNodes;

  # extract rootfs images for passthru
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
