defmodule Attest.TestScriptTest do
  use ExUnit.Case

  alias Attest.{Driver, TestScript}
  alias Attest.Machine.Backend

  setup do
    Process.flag(:trap_exit, true)
    id = :rand.uniform(1_000_000)
    %{id: id}
  end

  describe "eval_string/2" do
    test "evaluates elixir code with machine bindings", %{id: id} do
      name = "server_ts_#{id}"

      {:ok, driver} =
        Driver.start_link(machines: [%{name: name, backend: Backend.Mock}])

      {:ok, machine} = Driver.get_machine(driver, name)

      result = TestScript.eval_string("server_ts_#{id}", driver)
      assert result == machine

      GenServer.stop(driver)
    end

    test "provides start_all binding", %{id: id} do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "sa_#{id}", backend: Backend.Mock}])

      result = TestScript.eval_string("start_all.()", driver)
      assert result == :ok

      GenServer.stop(driver)
    end

    test "provides driver binding", %{id: id} do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "db_#{id}", backend: Backend.Mock}])

      result = TestScript.eval_string("driver", driver)
      assert result == driver

      GenServer.stop(driver)
    end

    test "has access to Attest module functions", %{id: id} do
      name = "node_#{id}"

      {:ok, driver} =
        Driver.start_link(machines: [%{name: name, backend: Backend.Mock}])

      result = TestScript.eval_string("Attest.Machine.booted?(node_#{id})", driver)
      assert result == false

      GenServer.stop(driver)
    end

    test "auto-imports Attest functions (no prefix needed)", %{id: id} do
      name = "srv_#{id}"

      {:ok, driver} =
        Driver.start_link(machines: [%{name: name, backend: Backend.Mock}])

      # start_all, succeed, wait_for_unit etc should work without Attest. prefix
      result = TestScript.eval_string("start_all.()", driver)
      assert result == :ok

      GenServer.stop(driver)
    end

    test "auto-imports DSL functions", %{id: id} do
      name = "dsl_#{id}"

      {:ok, driver} =
        Driver.start_link(machines: [%{name: name, backend: Backend.Mock}])

      result =
        TestScript.eval_string(
          ~s|assert_contains("hello world", "world")|,
          driver
        )

      assert result == :ok

      GenServer.stop(driver)
    end

    test "subtest macro works in eval'd scripts", %{id: id} do
      name = "sub_#{id}"

      {:ok, driver} =
        Driver.start_link(machines: [%{name: name, backend: Backend.Mock}])

      result =
        TestScript.eval_string(
          ~s|subtest("boot check", fn -> 42 end)|,
          driver
        )

      assert result == 42

      GenServer.stop(driver)
    end
  end

  describe "eval_file/2" do
    test "evaluates an elixir script file with bindings", %{id: id} do
      name = "web_#{id}"

      {:ok, driver} =
        Driver.start_link(machines: [%{name: name, backend: Backend.Mock}])

      path = Path.join(System.tmp_dir!(), "test-script-#{id}.exs")
      File.write!(path, "Attest.Machine.booted?(web_#{id})")

      result = TestScript.eval_file(path, driver)
      assert result == false

      File.rm!(path)
      GenServer.stop(driver)
    end
  end
end
