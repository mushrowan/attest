# benchmark comparing QEMU vs firecracker vs cloud-hypervisor boot times
#
# runs each backend through: boot -> wait_for_unit -> execute -> shutdown
# prints timing for each phase. not a check (too slow), run manually:
#
#   nix build .#bench && cat result/bench.txt
{
  pkgs,
  attest,
}:
let
  inherit (pkgs) lib;

  # shared NixOS config (empty = minimal system)
  nodeConfig = { };

  # build a QEMU test
  qemuTest = import ./make-test.nix {
    inherit pkgs attest;
    name = "bench-qemu";
    nodes.machine = nodeConfig;
    testScript = ''
      t0 = System.monotonic_time(:millisecond)

      start_all.()
      boot_ms = System.monotonic_time(:millisecond) - t0

      t1 = System.monotonic_time(:millisecond)
      Attest.wait_for_unit(machine, "multi-user.target")
      unit_ms = System.monotonic_time(:millisecond) - t1

      t2 = System.monotonic_time(:millisecond)
      Attest.succeed(machine, "echo bench-ok")
      exec_ms = System.monotonic_time(:millisecond) - t2

      IO.puts("BENCH qemu boot=#{boot_ms} unit=#{unit_ms} exec=#{exec_ms} total=#{boot_ms + unit_ms + exec_ms}")
    '';
  };

  # build a firecracker test (split store for fair comparison)
  firecrackerTest = import ./firecracker/make-test.nix {
    inherit pkgs attest;
    name = "bench-fc";
    splitStore = true;
    nodes.machine = nodeConfig;
    testScript = ''
      t0 = System.monotonic_time(:millisecond)

      start_all.()
      boot_ms = System.monotonic_time(:millisecond) - t0

      t1 = System.monotonic_time(:millisecond)
      Attest.wait_for_unit(machine, "multi-user.target")
      unit_ms = System.monotonic_time(:millisecond) - t1

      t2 = System.monotonic_time(:millisecond)
      Attest.succeed(machine, "echo bench-ok")
      exec_ms = System.monotonic_time(:millisecond) - t2

      IO.puts("BENCH firecracker boot=#{boot_ms} unit=#{unit_ms} exec=#{exec_ms} total=#{boot_ms + unit_ms + exec_ms}")
    '';
  };

  # build a cloud-hypervisor test (split store for fair comparison)
  cloudHypervisorTest = import ./cloud-hypervisor/make-test.nix {
    inherit pkgs attest;
    name = "bench-ch";
    splitStore = true;
    nodes.machine = nodeConfig;
    testScript = ''
      t0 = System.monotonic_time(:millisecond)

      start_all.()
      boot_ms = System.monotonic_time(:millisecond) - t0

      t1 = System.monotonic_time(:millisecond)
      Attest.wait_for_unit(machine, "multi-user.target")
      unit_ms = System.monotonic_time(:millisecond) - t1

      t2 = System.monotonic_time(:millisecond)
      Attest.succeed(machine, "echo bench-ok")
      exec_ms = System.monotonic_time(:millisecond) - t2

      IO.puts("BENCH cloud-hypervisor boot=#{boot_ms} unit=#{unit_ms} exec=#{exec_ms} total=#{boot_ms + unit_ms + exec_ms}")
    '';
  };

  # build a firecracker snapshot/restore bench (split store)
  firecrackerSnapshotTest = import ./firecracker/make-test.nix {
    inherit pkgs attest;
    name = "bench-fc-snapshot";
    splitStore = true;
    nodes.machine = nodeConfig;
    testScript = ''
      t0 = System.monotonic_time(:millisecond)

      start_all.()
      Attest.wait_for_unit(machine, "multi-user.target")
      cold_boot_ms = System.monotonic_time(:millisecond) - t0

      # create snapshot
      Attest.snapshot_create(machine, "/tmp/bench-snapshot")

      # restore
      t1 = System.monotonic_time(:millisecond)
      Attest.snapshot_restore(machine, "/tmp/bench-snapshot")
      restore_ms = System.monotonic_time(:millisecond) - t1

      t2 = System.monotonic_time(:millisecond)
      Attest.succeed(machine, "echo bench-ok")
      exec_ms = System.monotonic_time(:millisecond) - t2

      IO.puts("BENCH fc-snapshot cold_boot=#{cold_boot_ms} restore=#{restore_ms} exec_after_restore=#{exec_ms}")
    '';
  };

in
pkgs.runCommand "attest-bench"
  {
    requiredSystemFeatures = [
      "nixos-test"
      "kvm"
    ];
  }
  ''
    mkdir -p $out
    export HOME=$TMPDIR

    echo "=== attest backend benchmark ===" | tee $out/bench.txt
    echo "" | tee -a $out/bench.txt

    echo "--- qemu (attest) ---" | tee -a $out/bench.txt
    ${qemuTest.driver}/bin/attest-driver -o $out/qemu 2>&1 | grep "^BENCH" | tee -a $out/bench.txt
    echo "" | tee -a $out/bench.txt

    echo "--- firecracker (attest) ---" | tee -a $out/bench.txt
    ${firecrackerTest.driver}/bin/attest-driver -o $out/fc 2>&1 | grep "^BENCH" | tee -a $out/bench.txt
    echo "" | tee -a $out/bench.txt

    echo "--- cloud-hypervisor (attest) ---" | tee -a $out/bench.txt
    ${cloudHypervisorTest.driver}/bin/attest-driver -o $out/ch 2>&1 | grep "^BENCH" | tee -a $out/bench.txt
    echo "" | tee -a $out/bench.txt

    echo "--- firecracker snapshot/restore (attest) ---" | tee -a $out/bench.txt
    ${firecrackerSnapshotTest.driver}/bin/attest-driver -o $out/fc-snapshot 2>&1 | grep "^BENCH" | tee -a $out/bench.txt
    echo "" | tee -a $out/bench.txt

    echo "=== done ===" | tee -a $out/bench.txt
  ''
