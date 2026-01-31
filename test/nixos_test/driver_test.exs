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
  end
end
