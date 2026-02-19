# create a NixOS integration test using cloud-hypervisor VMs
#
# builds ext4 rootfs images and extracts vmlinux for each node,
# then runs the test via the elixir driver with backend=cloud-hypervisor.
# uses vsock for the shell backdoor (same transport as firecracker)
#
# networking: same bridge+TAP approach as firecracker. nodes get static
# IPs (192.168.{vlan}.{nodeNumber}), /etc/hosts for hostname resolution.
# auto-enables for multi-node tests or explicit enableNetwork=true
{
  pkgs,
  attest,
  # test name
  name,
  # attrset of node name -> NixOS module (or list of modules)
  nodes,
  # elixir test script string
  testScript,
  # list of VLAN numbers (non-empty enables networking)
  vlans ? [ ],
  # enable networking even without explicit VLANs (uses VLAN 1)
  enableNetwork ? false,
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

  # resolve effective VLANs
  effectiveVlans =
    if vlans != [ ] then
      vlans
    else if enableNetwork || (builtins.length (builtins.attrNames nodes)) > 1 then
      [ 1 ]
    else
      [ ];

  hasNetwork = effectiveVlans != [ ];

  # sorted node names for deterministic number assignment
  sortedNames = lib.sort (a: b: a < b) (builtins.attrNames nodes);

  nodeNumbers = lib.listToAttrs (lib.imap1 (idx: name: lib.nameValuePair name idx) sortedNames);

  # MAC address: AA:C0:00:{vlan}:{nodeNum}:01
  macAddress =
    vlan: nodeNum:
    let
      hex = n: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString n));
    in
    "AA:C0:00:${hex vlan}:${hex nodeNum}:01";

  tapName = nodeName: vlan: "t${toString nodeNumbers.${nodeName}}v${toString vlan}";

  bridgeName = vlan: "br${toString vlan}";

  hostsEntries = lib.concatStringsSep "\n" (
    lib.concatMap (
      nodeName:
      let
        num = nodeNumbers.${nodeName};
      in
      map (vlan: "192.168.${toString vlan}.${toString num} ${nodeName}") effectiveVlans
    ) sortedNames
  );

  nodeTaps =
    nodeName:
    lib.imap0 (idx: vlan: {
      iface_id = "eth${toString idx}";
      host_dev_name = tapName nodeName vlan;
      guest_mac = macAddress vlan (nodeNumbers.${nodeName});
    }) effectiveVlans;

  # evaluate a NixOS config for cloud-hypervisor
  evalNode =
    nodeName: nodeConfig:
    let
      modules = if builtins.isList nodeConfig then nodeConfig else [ nodeConfig ];
      nodeNum = nodeNumbers.${nodeName};

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
                ++ lib.optionals hasNetwork [
                  "virtio_net"
                ]
              );
              testing.splitStoreImage = splitStore;
              testing.nodeNumber = nodeNum;
              testing.vlans = effectiveVlans;
              testing.hostsEntries = hostsEntries;
            }
          ];

          networking.hostName = lib.mkDefault nodeName;
        };
      };

      toplevel = nixos.config.system.build.toplevel;
      # copy vmlinux out of kernel.dev to avoid the entire dev closure
      vmlinux = pkgs.runCommand "vmlinux" { } ''
        cp ${nixos.config.boot.kernelPackages.kernel.dev}/vmlinux $out
      '';
      initrd = "${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile}";
      bootArgs = builtins.concatStringsSep " " (
        nixos.config.boot.kernelParams ++ [ "init=${toplevel}/init" ]
      );

      rootfs =
        if splitStore then
          import ../firecracker/make-rootfs-minimal.nix {
            inherit pkgs toplevel name;
          }
        else
          import ../firecracker/make-rootfs.nix {
            inherit pkgs toplevel name;
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
    // lib.optionalAttrs hasNetwork {
      tap_interfaces = map (t: [
        t.iface_id
        t.host_dev_name
        t.guest_mac
      ]) (nodeTaps nodeName);
    }
  ) evaluatedNodes;

  # network setup script
  networkSetupScript = lib.optionalString hasNetwork ''
    ${lib.concatMapStringsSep "\n" (vlan: ''
      ip link add ${bridgeName vlan} type bridge
      ip link set ${bridgeName vlan} up
      ip addr add 192.168.${toString vlan}.254/24 dev ${bridgeName vlan}
    '') effectiveVlans}

    ${lib.concatMapStringsSep "\n" (
      nodeName:
      lib.concatMapStringsSep "\n" (
        vlan:
        let
          tap = tapName nodeName vlan;
        in
        ''
          ip tuntap add ${tap} mode tap
          ip link set ${tap} master ${bridgeName vlan}
          ip link set ${tap} up
        ''
      ) effectiveVlans
    ) sortedNames}
  '';

  rootfsImages = lib.mapAttrs (_: node: node.rootfs) evaluatedNodes;

  driver = import ../driver.nix {
    inherit
      pkgs
      attest
      globalTimeout
      extraDriverArgs
      name
      machines
      ;
    vlans = [ ];
    inherit testScript;
  };

  test = import ../run.nix {
    inherit pkgs driver name;
    preScript = networkSetupScript;
  };
in
test
// {
  inherit driver;
  inherit rootfsImages;
}
