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
  # networking: TAP interface configs per node + bridge setup script
  # needed so the guest NixOS config matches the VM's available devices
  tapInterfaces ? { },
  networkSetupScript ? "",
}:
let
  inherit (pkgs) lib;

  hasNetwork = networkSetupScript != "";
  sortedNames = lib.sort (a: b: a < b) (builtins.attrNames nodes);

  # elixir test script: boot each VM sequentially, snapshot, then kill
  # sequential to avoid resource contention in the nix sandbox builder
  # copies rootfs + snapshot to /tmp/snapshot-out/<name>/
  testScript = ''
    ${lib.concatMapStringsSep "\n" (nodeName: ''
      IO.puts("${nodeName}: starting")
      Attest.Machine.start(${nodeName})
      Attest.wait_for_unit(${nodeName}, "multi-user.target")
      Attest.succeed(${nodeName}, "sync")
      IO.puts("${nodeName}: ready, creating snapshot")
      Attest.snapshot_create(${nodeName}, "/tmp/snapshot-out/${nodeName}")
      state_dir = Attest.Machine.state_dir(${nodeName})
      rootfs = Path.join(state_dir, "rootfs.ext4")
      File.cp!(rootfs, "/tmp/snapshot-out/${nodeName}/rootfs.ext4")
      IO.puts("${nodeName}: snapshot + rootfs saved")
      # VM is paused after snapshot, force-kill it
      Attest.Machine.halt(${nodeName})
      IO.puts("${nodeName}: done")
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
    // lib.optionalAttrs (tapInterfaces ? ${nodeName}) {
      tap_interfaces = tapInterfaces.${nodeName};
    }
  ) nodes;

  machineConfigJson = builtins.toJSON {
    vlans = [ ];
    global_timeout = 600;
    inherit machines;
  };

  machineConfigFile = pkgs.writeText "machine-config-snapshot-${name}.json" machineConfigJson;
  testScriptFile = pkgs.writeText "snapshot-script-${name}.exs" testScript;

  wrapCmd =
    if hasNetwork then
      "${pkgs.util-linux}/bin/unshare --user --map-root-user --net ${pkgs.bash}/bin/bash -e"
    else
      "${pkgs.bash}/bin/bash -e";

in
pkgs.runCommand "vm-snapshots-${name}"
  {
    requiredSystemFeatures = [
      "nixos-test"
      "kvm"
    ];
    nativeBuildInputs = [
      pkgs.makeWrapper
    ]
    ++ lib.optionals hasNetwork [
      pkgs.iproute2
    ];
  }
  ''
    export HOME=$TMPDIR
    mkdir -p /tmp/snapshot-out

    # build driver wrapper
    mkdir -p $TMPDIR/driver/bin
    makeWrapper ${attest}/bin/attest $TMPDIR/driver/bin/attest-driver \
      --set machineConfig "${machineConfigFile}" \
      --set testScript "${testScriptFile}"

    ${wrapCmd} <<'INNER_SCRIPT'
    ${lib.optionalString hasNetwork ''
      ip link set lo up
    ''}

    ${networkSetupScript}

    if ! $TMPDIR/driver/bin/attest-driver; then
      echo "=== snapshot builder failed, dumping FC logs ==="
      for logfile in /build/vm-state/*/firecracker.log; do
        if [ -f "$logfile" ]; then
          echo "--- $logfile ---"
          cat "$logfile"
        fi
      done
      exit 1
    fi
    INNER_SCRIPT

    # copy snapshot outputs
    cp -r /tmp/snapshot-out $out
  ''
