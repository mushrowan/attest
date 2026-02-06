defmodule NixosTest.DriverTest do
  use ExUnit.Case

  alias NixosTest.Driver
  alias NixosTest.Machine.Backend

  setup do
    # prevent driver EXIT signals from killing the test process
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "Driver" do
    test "can start a driver process" do
      {:ok, pid} = Driver.start_link([])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "start_all returns ok" do
      {:ok, pid} = Driver.start_link([])
      assert :ok = Driver.start_all(pid)
      GenServer.stop(pid)
    end

    test "get_machine returns error for unknown machine" do
      {:ok, pid} = Driver.start_link([])
      assert {:error, :not_found} = Driver.get_machine(pid, "nonexistent")
      GenServer.stop(pid)
    end

    test "creates machines from config" do
      {:ok, driver} =
        Driver.start_link(machines: [%{name: "client", backend: Backend.Mock}])

      assert {:ok, machine_pid} = Driver.get_machine(driver, "client")
      assert Process.alive?(machine_pid)

      GenServer.stop(driver)
    end

    test "start_all boots all machines" do
      {:ok, driver} =
        Driver.start_link(
          machines: [
            %{name: "m1", backend: Backend.Mock},
            %{name: "m2", backend: Backend.Mock}
          ]
        )

      {:ok, m1} = Driver.get_machine(driver, "m1")
      {:ok, m2} = Driver.get_machine(driver, "m2")
      refute NixosTest.Machine.booted?(m1)
      refute NixosTest.Machine.booted?(m2)

      :ok = Driver.start_all(driver)

      assert NixosTest.Machine.booted?(m1)
      assert NixosTest.Machine.booted?(m2)

      GenServer.stop(driver)
    end

    test "machines are stopped when driver terminates" do
      {:ok, driver} =
        Driver.start_link(
          machines: [
            %{name: "cleanup1", backend: Backend.Mock},
            %{name: "cleanup2", backend: Backend.Mock}
          ]
        )

      {:ok, m1} = Driver.get_machine(driver, "cleanup1")
      {:ok, m2} = Driver.get_machine(driver, "cleanup2")

      assert Process.alive?(m1)
      assert Process.alive?(m2)

      ref1 = Process.monitor(m1)
      ref2 = Process.monitor(m2)

      GenServer.stop(driver)

      assert_receive {:DOWN, ^ref1, :process, ^m1, _}, 5000
      assert_receive {:DOWN, ^ref2, :process, ^m2, _}, 5000
    end
  end
end
