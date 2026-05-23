defmodule Nix.PerfBudgetTest do
  use ExUnit.Case, async: true

  test "perf budget keeps full phase table but prints slow phases only" do
    source = File.read!("nix/perf-budget.nix")

    assert source =~ "backend-phases.tsv"
    assert source =~ "slow-phases.tsv"
    assert source =~ "head -n 12"
    assert source =~ "full backend phase table"
  end
end

defmodule Nix.IntegrationTestsTest do
  use ExUnit.Case, async: true

  test "legacy integration tests wrap attest at build time" do
    source = File.read!("integration-tests/default.nix")

    assert source =~ "nativeBuildInputs = [ pkgs.makeWrapper ]"
    assert source =~ "makeWrapper ${attest}/bin/attest $TMPDIR/attest-driver"
  end
end

defmodule Nix.TestCheckTest do
  use ExUnit.Case, async: true

  test "nix unit test check reuses the package source filter" do
    source = File.read!("flake.nix")

    assert source =~ "src = attest.src"
  end
end
