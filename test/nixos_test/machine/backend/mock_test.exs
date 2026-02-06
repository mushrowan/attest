defmodule NixosTest.Machine.Backend.MockTest do
  use ExUnit.Case, async: true

  alias NixosTest.Machine.Backend.Mock
  alias NixosTest.Machine.{QMP, Shell}

  describe "init/1" do
    test "stores injected shell pid" do
      shell = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, state} = Mock.init(%{shell: shell})
      assert state.shell == shell
    end

    test "stores injected qmp pid" do
      qmp = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, state} = Mock.init(%{qmp: qmp})
      assert state.qmp == qmp
    end
  end

  describe "start/1" do
    test "returns injected shell pid" do
      shell = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, state} = Mock.init(%{shell: shell})

      assert {:ok, ^shell, _new_state} = Mock.start(state)
    end

    test "returns nil shell when none injected" do
      {:ok, state} = Mock.init(%{})
      assert {:ok, nil, _new_state} = Mock.start(state)
    end
  end

  describe "lifecycle" do
    test "shutdown returns :ok" do
      {:ok, state} = Mock.init(%{})
      assert :ok = Mock.shutdown(state, 5000)
    end

    test "halt returns :ok" do
      {:ok, state} = Mock.init(%{})
      assert :ok = Mock.halt(state, 5000)
    end

    test "wait_for_shutdown returns :ok" do
      {:ok, state} = Mock.init(%{})
      assert :ok = Mock.wait_for_shutdown(state, 5000)
    end

    test "cleanup returns :ok" do
      {:ok, state} = Mock.init(%{})
      assert :ok = Mock.cleanup(state)
    end
  end

  describe "screenshot/2" do
    test "delegates to QMP when available" do
      socket_path = Path.join(System.tmp_dir!(), "qmp-mock-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:packet, :line},
          {:active, false},
          {:ip, {:local, socket_path}}
        ])

      test_pid = self()

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)

        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))
        # screendump command
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        receive do
          :stop -> :ok
        end
      end)

      {:ok, qmp} = QMP.start_link(socket_path: socket_path)
      {:ok, state} = Mock.init(%{qmp: qmp})

      assert :ok = Mock.screenshot(state, "/tmp/test.ppm")
      assert_receive {:qmp_command, cmd}, 1000
      assert cmd =~ "screendump"

      GenServer.stop(qmp)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end

    test "returns unsupported when no QMP" do
      {:ok, state} = Mock.init(%{})
      assert {:error, :unsupported} = Mock.screenshot(state, "/tmp/test.ppm")
    end
  end

  describe "capabilities/0" do
    test "returns screenshot when qmp available" do
      qmp = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, state} = Mock.init(%{qmp: qmp})
      assert :screenshot in Mock.capabilities(state)
    end

    test "returns empty when no qmp" do
      {:ok, state} = Mock.init(%{})
      assert Mock.capabilities(state) == []
    end
  end
end
