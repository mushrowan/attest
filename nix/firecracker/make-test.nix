# create a NixOS integration test using firecracker VMs
#
# builds ext4 rootfs images and extracts vmlinux for each node,
# then runs the test via the elixir driver with backend=firecracker
#
# two rootfs modes:
# - splitStore=false (default): entire closure in ext4 (simple, ~1.2GB)
# - splitStore=true: minimal ext4 + erofs nix store (fast, ~350MB)
#
# networking:
# - when vlans is non-empty (or enableNetwork=true), creates a bridge per
#   vlan and a TAP interface per node. IPs are 192.168.{vlan}.{nodeNumber}
# - node numbers are assigned alphabetically starting from 1
# - /etc/hosts is populated so nodes can reach each other by hostname
#
# usage:
#   test = import ./make-test.nix {
#     inherit pkgs attest;
#     name = "my-test";
#     splitStore = true;
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
  # use 2MB huge pages for guest memory (requires hugetlbfs on host)
  hugePages ? false,
  # enable virtio-rng entropy device
  entropy ? true,
}:
let
  inherit (pkgs) lib;

  # resolve effective VLANs: if enableNetwork or multi-node, default to [1]
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

  # node number: alphabetically sorted, 1-indexed
  nodeNumbers = lib.listToAttrs (lib.imap1 (idx: name: lib.nameValuePair name idx) sortedNames);

  # generate a deterministic MAC address: AA:FC:00:{vlan}:{nodeNum}:01
  macAddress =
    vlan: nodeNum:
    let
      hex = n: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString n));
    in
    "AA:FC:00:${hex vlan}:${hex nodeNum}:01";

  # TAP device name: t{nodeNumber}v{vlan} - short, unique, max 15 chars
  tapName = nodeName: vlan: "t${toString nodeNumbers.${nodeName}}v${toString vlan}";

  # bridge name per vlan
  bridgeName = vlan: "br${toString vlan}";

  # /etc/hosts entries: all nodes on all VLANs
  hostsEntries = lib.concatStringsSep "\n" (
    lib.concatMap (
      nodeName:
      let
        num = nodeNumbers.${nodeName};
      in
      map (vlan: "192.168.${toString vlan}.${toString num} ${nodeName}") effectiveVlans
    ) sortedNames
  );

  # build TAP interface list for a node: [{iface_id, host_dev_name, guest_mac}]
  nodeTaps =
    nodeName:
    lib.imap0 (idx: vlan: {
      iface_id = "eth${toString idx}";
      host_dev_name = tapName nodeName vlan;
      guest_mac = macAddress vlan (nodeNumbers.${nodeName});
    }) effectiveVlans;

  # evaluate a NixOS config for firecracker
  evalNode =
    nodeName: nodeConfig:
    let
      modules = if builtins.isList nodeConfig then nodeConfig else [ nodeConfig ];
      nodeNum = nodeNumbers.${nodeName};

      nixos = import "${pkgs.path}/nixos" {
        system = pkgs.stdenv.hostPlatform.system;
        configuration = {
          imports = modules ++ [
            ./test-instrumentation.nix
          ];

          networking.hostName = lib.mkDefault nodeName;
          testing.splitStoreImage = splitStore;
          testing.nodeNumber = nodeNum;
          testing.vlans = effectiveVlans;
          testing.hostsEntries = hostsEntries;
        };
      };

      toplevel = nixos.config.system.build.toplevel;
      # copy vmlinux out of kernel.dev to avoid dragging in the entire
      # dev output (580MB) + rustc (995MB) + llvm (541MB) into the closure
      vmlinux = pkgs.runCommand "vmlinux" { } ''
        cp ${nixos.config.boot.kernelPackages.kernel.dev}/vmlinux $out
      '';
      initrd = "${nixos.config.system.build.initialRamdisk}/${nixos.config.system.boot.loader.initrdFile}";

      bootArgs = builtins.concatStringsSep " " (
        nixos.config.boot.kernelParams ++ [ "init=${toplevel}/init" ]
      );

      rootfs =
        if splitStore then
          import ./make-rootfs-minimal.nix {
            inherit pkgs toplevel name;
          }
        else
          import ./make-rootfs.nix {
            inherit pkgs toplevel name;
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

  # single shared store image containing the union of all node closures
  # avoids duplicating ~1.8GB per node in the nix sandbox
  sharedStoreImage = lib.optionalAttrs splitStore (
    import ./make-shared-store-image.nix {
      inherit pkgs;
      toplevels = lib.mapAttrsToList (_: node: node.toplevel) evaluatedNodes;
    }
  );

  # build machine config list for the driver
  machines = lib.mapAttrsToList (
    nodeName: node:
    {
      name = nodeName;
      backend = "firecracker";
      firecracker_bin = "${pkgs.firecracker}/bin/firecracker";
      kernel_image_path = node.vmlinux;
      initrd_path = node.initrd;
      rootfs_path = "${node.rootfs}";
      kernel_boot_args = node.bootArgs;
      mem_size_mib = memSize;
      vcpu_count = vcpuCount;
      entropy = entropy;
    }
    // lib.optionalAttrs hugePages {
      huge_pages = "2M";
    }
    // lib.optionalAttrs splitStore {
      store_image_path = "${sharedStoreImage}";
    }
    // lib.optionalAttrs hasNetwork {
      tap_interfaces = map (t: [
        t.iface_id
        t.host_dev_name
        t.guest_mac
      ]) (nodeTaps nodeName);
    }
  ) evaluatedNodes;

  # network setup script: create bridges and TAPs before VMs boot
  networkSetupScript = lib.optionalString hasNetwork ''
    # create bridges
    ${lib.concatMapStringsSep "\n" (vlan: ''
      ip link add ${bridgeName vlan} type bridge
      ip link set ${bridgeName vlan} up
      ip addr add 192.168.${toString vlan}.254/24 dev ${bridgeName vlan}
    '') effectiveVlans}

    # create TAP devices and attach to bridges
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
    vlans = [ ]; # VDE vlans not used with firecracker networking
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
