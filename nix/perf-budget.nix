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
    phases=$out/backend-phases.tsv
    slow_phases=$out/slow-phases.tsv
    echo -e "check\tduration_ms\twarn_ms\tstatus" > "$summary"
    echo -e "check\tmachine\tbackend\tphase\tduration_ms\tcpu_us\treductions" > "$phases"
    echo -e "check\tmachine\tbackend\tphase\tduration_ms\tcpu_us\treductions" > "$slow_phases"

    ${pkgs.lib.concatStringsSep "\n" (
      pkgs.lib.mapAttrsToList (name: cfg: ''
        timing_file="${cfg.drv}/timings.json"
        if [ ! -f "$timing_file" ]; then
          echo -e "${name}\tmissing\t${toString cfg.maxMs}\twarn" >> "$summary"
          echo "warning: missing timing file for ${name}: $timing_file" >&2
        else
          duration=$(jq -r '.duration_ms' "$timing_file")
          if [ "$duration" -le ${toString cfg.maxMs} ]; then
            status=ok
          else
            status=warn
            echo "warning: ${name} took ''${duration}ms, budget is ${toString cfg.maxMs}ms" >&2
          fi

          echo -e "${name}\t$duration\t${toString cfg.maxMs}\t$status" >> "$summary"
        fi

        if [ -d "${cfg.drv}/machines" ]; then
          find "${cfg.drv}/machines" -mindepth 2 -maxdepth 2 -name metadata.json -print0 |
            while IFS= read -r -d ''' metadata_file; do
              jq -r --arg check "${name}" '
                . as $machine
                | ($machine.backend_timings // [])[]
                | [
                    $check,
                    ($machine.name // "unknown"),
                    ($machine.backend // "unknown"),
                    (.operation // "unknown"),
                    (.duration_ms // 0),
                    (.cpu_us // 0),
                    (.reductions // 0)
                  ]
                | @tsv
              ' "$metadata_file" >> "$phases"
            done
        fi
      '') budgetedChecks
    )}

    cat "$summary" >&2
    if [ "$(wc -l < "$phases")" -gt 1 ]; then
      echo >&2
      {
        head -n 1 "$phases"
        tail -n +2 "$phases" | sort -t $'\t' -k5,5nr | head -n 12
      } > "$slow_phases"

      cat "$slow_phases" >&2
      echo "full backend phase table: $phases" >&2
    fi
  ''
