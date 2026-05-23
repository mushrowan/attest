{
  pkgs,
  attest,
  name,
  node,
}:
let
  vm = node.vm;
  systemName = node.config.system.name;
in
pkgs.runCommand "qemu-snapshot-${name}"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail

    export STATE_DIR=$(mktemp -d)
    export HOME=$TMPDIR
    export ERL_FLAGS="+fnu"
    export ATTEST_LOG_LEVEL=debug

    cat > $TMPDIR/snapshot.exs <<'ELIXIR'
    {:ok, machine} =
      Attest.Machine.start_link(
        name: "${name}",
        backend: Attest.Machine.Backend.QEMU,
        start_command: System.fetch_env!("START_COMMAND"),
        qmp_socket_path: System.fetch_env!("QMP_SOCKET"),
          shell_socket_path: System.fetch_env!("SHELL_SOCKET"),
          state_dir: System.fetch_env!("MACHINE_STATE_DIR")
      )

    :ok = Attest.Machine.start(machine)
    :ok = Attest.Machine.wait_for_unit(machine, "multi-user.target", 120_000)
    :ok = Attest.Machine.succeed(machine, "sync")
    :ok = Attest.Machine.snapshot_create(machine, System.fetch_env!("SNAPSHOT_DIR"))
    :ok = Attest.Machine.halt(machine, 30_000)
    ELIXIR

    machine_state=$STATE_DIR/vm-state-${name}
    mkdir -p "$machine_state" $out

    export QMP_SOCKET=$machine_state/qmp
    export SHELL_SOCKET=$machine_state/shell
    export MACHINE_STATE_DIR=$machine_state
    export SNAPSHOT_DIR=$out
    export DISK_IMAGE=$TMPDIR/${name}.qcow2
    export OUT_DISK_IMAGE=$out/${name}.qcow2

    export START_COMMAND="env TMPDIR=$machine_state USE_TMPDIR=1 SHARED_DIR=$machine_state/shared NIX_DISK_IMAGE=$DISK_IMAGE ${vm}/bin/run-${systemName}-vm -qmp unix:$QMP_SOCKET,server=on,wait=off -chardev socket,id=shell,path=$SHELL_SOCKET -device virtio-serial -device virtconsole,chardev=shell -nographic -no-reboot"
    makeWrapper ${attest}/bin/attest $TMPDIR/attest \
      --set ERL_FLAGS "+fnu"

    $TMPDIR/attest --verbose --test-script $TMPDIR/snapshot.exs
    cp --reflink=auto "$DISK_IMAGE" "$OUT_DISK_IMAGE"
  ''
