{ pkgs, checks }:

let
  budgetedChecks = {
    integration = {
      drv = checks.integration;
      maxMs = 20000;
    };
    integration-multi-vm = {
      drv = checks.integration-multi-vm;
      maxMs = 25000;
    };
    make-test-smoke = {
      drv = checks.make-test-smoke;
      maxMs = 20000;
    };
    make-test-multi = {
      drv = checks.make-test-multi;
      maxMs = 25000;
    };
    firecracker-smoke = {
      drv = checks.firecracker-smoke;
      maxMs = 20000;
    };
    firecracker-split = {
      drv = checks.firecracker-split;
      maxMs = 20000;
    };
    firecracker-prebuilt = {
      drv = checks.firecracker-prebuilt;
      maxMs = 10000;
    };
    cloud-hypervisor-smoke = {
      drv = checks.cloud-hypervisor-smoke;
      maxMs = 20000;
    };
  };
in
pkgs.runCommand "attest-perf-budget"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    set -euo pipefail

    mkdir -p $out
    summary=$out/summary.tsv
    echo -e "check\tduration_ms\tmax_ms\tstatus" > "$summary"

    failures=0

    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        timing_file="${cfg.drv}/timings.json"
        if [ ! -f "$timing_file" ]; then
          echo -e "${name}\tmissing\t${toString cfg.maxMs}\tfail" >> "$summary"
          echo "missing timing file for ${name}: $timing_file" >&2
          failures=$((failures + 1))
        else
          duration=$(jq -r '.duration_ms' "$timing_file")
          if [ "$duration" -le ${toString cfg.maxMs} ]; then
            status=ok
          else
            status=fail
            failures=$((failures + 1))
          fi

          echo -e "${name}\t$duration\t${toString cfg.maxMs}\t$status" >> "$summary"
        fi
      '') budgetedChecks
    )}

    cat "$summary" >&2

    if [ "$failures" -ne 0 ]; then
      exit 1
    fi
  ''
