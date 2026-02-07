defmodule NixosTest.TestScriptTest do
  use ExUnit.Case

  alias NixosTest.{Driver, TestScript}
  alias NixosTest.Machine.Backend

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "eval_string/2" do
    test "evaluates elixir code with machine bindings" do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "server", backend: Backend.Mock}])

      {:ok, machine} = Driver.get_machine(driver, "server")

      result = TestScript.eval_string("server", driver)
      assert result == machine

      GenServer.stop(driver)
    end

    test "provides start_all binding" do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "m1", backend: Backend.Mock}])

      result = TestScript.eval_string("start_all.()", driver)
      assert result == :ok

      GenServer.stop(driver)
    end

    test "provides driver binding" do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "driver-bind", backend: Backend.Mock}])

      result = TestScript.eval_string("driver", driver)
      assert result == driver

      GenServer.stop(driver)
    end

    test "has access to NixosTest module functions" do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "node", backend: Backend.Mock}])

      # should be able to call NixosTest functions
      result = TestScript.eval_string("NixosTest.Machine.booted?(node)", driver)
      assert result == false

      GenServer.stop(driver)
    end
  end

  describe "eval_file/2" do
    test "evaluates an elixir script file with bindings" do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "web", backend: Backend.Mock}])

      path = Path.join(System.tmp_dir!(), "test-script-#{:rand.uniform(100_000)}.exs")
      File.write!(path, "NixosTest.Machine.booted?(web)")

      result = TestScript.eval_file(path, driver)
      assert result == false

      File.rm!(path)
      GenServer.stop(driver)
    end
  end
end
