# build pre-warmed VM snapshots for fast test startup
#
# boots each node's VM, waits for multi-user.target, syncs filesystems,
# creates a firecracker snapshot, then copies the snapshot files and
# modified rootfs to $out. cached by nix, only rebuilt when NixOS
# config changes
#
# output: $out/<nodeName>/{snapshot_file,mem_file,rootfs.ext4}
#
# requires KVM access (nixos-test sandbox feature)
{
  pkgs,
  attest,
  # attrset of evaluatedNodes (from make-test.nix's evalNode)
  nodes,
  # shared store image path (if splitStore)
  sharedStoreImage ? null,
  firecrackerPackage ? pkgs.firecracker,
  name ? "attest",
  memSize ? 256,
  vcpuCount ? 1,
  entropy ? true,
  splitStore ? false,
}:
let
  inherit (pkgs) lib;

  sortedNames = lib.sort (a: b: a < b) (builtins.attrNames nodes);

  # elixir test script: boot all, wait for ready, snapshot each
  # copies rootfs + snapshot to /tmp/snapshot-out/<name>/
  testScript = ''
    start_all.()

    ${lib.concatMapStringsSep "\n" (nodeName: ''
      Attest.wait_for_unit(${nodeName}, "multi-user.target")
      Attest.succeed(${nodeName}, "sync")
      IO.puts("${nodeName}: ready, creating snapshot")
      Attest.snapshot_create(${nodeName}, "/tmp/snapshot-out/${nodeName}")
      IO.puts("${nodeName}: snapshot created")
    '') sortedNames}

    # copy rootfs files next to snapshots (rootfs was modified during boot)
    ${lib.concatMapStringsSep "\n" (nodeName: ''
      state_dir = Attest.Machine.state_dir(${nodeName})
      rootfs = Path.join(state_dir, "rootfs.ext4")
      File.cp!(rootfs, "/tmp/snapshot-out/${nodeName}/rootfs.ext4")
      IO.puts("${nodeName}: rootfs copied")
    '') sortedNames}

    IO.puts("all snapshots ready")
  '';

  machines = lib.mapAttrsToList (
    nodeName: node:
    {
      name = nodeName;
      backend = "firecracker";
      firecracker_bin = "${firecrackerPackage}/bin/firecracker";
      kernel_image_path = node.vmlinux;
      initrd_path = node.initrd;
      rootfs_path = "${node.rootfs}";
      kernel_boot_args = node.bootArgs;
      mem_size_mib = memSize;
      vcpu_count = vcpuCount;
      inherit entropy;
    }
    // lib.optionalAttrs (splitStore && sharedStoreImage != null) {
      store_image_path = "${sharedStoreImage}";
    }
  ) nodes;

  machineConfigJson = builtins.toJSON {
    vlans = [ ];
    global_timeout = 300;
    inherit machines;
  };

  machineConfigFile = pkgs.writeText "machine-config-snapshot-${name}.json" machineConfigJson;
  testScriptFile = pkgs.writeText "snapshot-script-${name}.exs" testScript;

in
pkgs.runCommand "vm-snapshots-${name}"
  {
    requiredSystemFeatures = [
      "nixos-test"
      "kvm"
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
  }
  ''
    export HOME=$TMPDIR
    mkdir -p /tmp/snapshot-out

    # build driver wrapper
    mkdir -p $TMPDIR/driver/bin
    makeWrapper ${attest}/bin/attest $TMPDIR/driver/bin/attest-driver \
      --set machineConfig "${machineConfigFile}" \
      --set testScript "${testScriptFile}"

    $TMPDIR/driver/bin/attest-driver

    # copy snapshot outputs
    cp -r /tmp/snapshot-out $out
  ''
