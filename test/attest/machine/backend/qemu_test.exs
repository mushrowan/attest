defmodule Attest.Machine.Backend.QEMUTest do
  use ExUnit.Case

  alias Attest.Machine.Backend.QEMU

  describe "init/1" do
    test "stores config" do
      config = %{
        name: "test",
        start_command: "echo hello",
        qmp_socket_path: "/tmp/qmp.sock",
        shell_socket_path: "/tmp/shell.sock"
      }

      assert {:ok, state} = QEMU.init(config)
      assert state.name == "test"
      assert state.start_command == "echo hello"
      assert state.qmp_socket_path == "/tmp/qmp.sock"
      assert state.shell_socket_path == "/tmp/shell.sock"
    end
  end

  describe "start/1" do
    test "spawns process and creates shell" do
      shell_path = Path.join(System.tmp_dir!(), "qemu-be-shell-#{:rand.uniform(10000)}.sock")
      File.rm(shell_path)

      {:ok, state} =
        QEMU.init(%{
          name: "start-test",
          start_command: "sleep 1",
          shell_socket_path: shell_path
        })

      test_pid = self()

      # simulate guest connecting to shell
      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, shell_path}, 0, [
            :binary,
            {:packet, :line},
            {:active, false}
          ])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")
        send(test_pid, :guest_connected)

        receive do
          :stop -> :ok
        after
          5000 -> :ok
        end
      end)

      assert {:ok, shell_pid, new_state} = QEMU.start(state)
      assert is_pid(shell_pid)
      assert new_state.qemu_port != nil
      assert_receive :guest_connected, 2000

      # cleanup
      QEMU.cleanup(new_state)
      File.rm(shell_path)
    end

    test "connects to QMP when socket path provided" do
      qmp_path = Path.join(System.tmp_dir!(), "qemu-be-qmp-#{:rand.uniform(10000)}.sock")
      File.rm(qmp_path)

      # mock QMP server
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:packet, :line},
          {:active, false},
          {:ip, {:local, qmp_path}}
        ])

      test_pid = self()

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen, 5000)

        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))
        send(test_pid, :qmp_negotiated)

        receive do
          :stop -> :ok
        after
          5000 -> :ok
        end
      end)

      {:ok, state} =
        QEMU.init(%{
          name: "qmp-test",
          qmp_socket_path: qmp_path
        })

      assert {:ok, _shell, new_state} = QEMU.start(state)
      assert new_state.qmp != nil
      assert_receive :qmp_negotiated, 2000

      QEMU.cleanup(new_state)
      :gen_tcp.close(listen)
      File.rm(qmp_path)
    end
  end

  describe "halt/2" do
    test "sends QMP quit" do
      qmp_path = Path.join(System.tmp_dir!(), "qemu-be-halt-#{:rand.uniform(10000)}.sock")
      File.rm(qmp_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:packet, :line},
          {:active, false},
          {:ip, {:local, qmp_path}}
        ])

      test_pid = self()

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen, 5000)

        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        # receive quit command
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        Process.sleep(100)
      end)

      {:ok, state} =
        QEMU.init(%{
          name: "halt-test",
          start_command: "sleep 0.2",
          qmp_socket_path: qmp_path
        })

      {:ok, _shell, state} = QEMU.start(state)

      assert :ok = QEMU.halt(state, 5000)
      assert_receive {:qmp_command, cmd}, 2000
      assert cmd =~ "quit"

      :gen_tcp.close(listen)
      File.rm(qmp_path)
    end
  end

  describe "capabilities/1" do
    test "includes screenshot" do
      assert :screenshot in QEMU.capabilities(%{})
    end
  end
end
