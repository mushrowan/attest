defmodule NixosTest.DriverTest do
  use ExUnit.Case

  alias NixosTest.Driver

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
      {:ok, driver} = Driver.start_link(machines: [%{name: "client"}])

      assert {:ok, machine_pid} = Driver.get_machine(driver, "client")
      assert Process.alive?(machine_pid)

      GenServer.stop(driver)
    end

    test "start_all boots all machines" do
      {:ok, driver} = Driver.start_link(machines: [%{name: "m1"}, %{name: "m2"}])

      # machines start not booted
      {:ok, m1} = Driver.get_machine(driver, "m1")
      {:ok, m2} = Driver.get_machine(driver, "m2")
      refute NixosTest.Machine.booted?(m1)
      refute NixosTest.Machine.booted?(m2)

      # start_all boots them
      :ok = Driver.start_all(driver)

      assert NixosTest.Machine.booted?(m1)
      assert NixosTest.Machine.booted?(m2)

      GenServer.stop(driver)
    end
  end
end
