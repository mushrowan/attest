defmodule NixosTest.MachineTest do
  use ExUnit.Case

  alias NixosTest.Machine

  describe "Machine" do
    test "can start a machine process" do
      {:ok, pid} = Machine.start_link(name: "test-machine")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "execute returns not_implemented for now" do
      {:ok, pid} = Machine.start_link(name: "test-machine-2")
      assert {:error, :not_implemented} = Machine.execute(pid, "echo hello")
      GenServer.stop(pid)
    end
  end
end
