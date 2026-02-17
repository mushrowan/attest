defmodule Attest.Machine.Shell.Transport.VsockTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.Shell.Transport.Vsock

  alias Attest.Machine.Shell

  describe "connect/2" do
    test "connects to vsock UDS and sends CONNECT protocol" do
      uds_path = Path.join(System.tmp_dir!(), "vsock-test-#{:rand.uniform(100_000)}.sock")
      File.rm(uds_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:active, false},
          {:ip, {:local, uds_path}}
        ])

      test_pid = self()

      # mock firecracker vsock handler
      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        {:ok, data} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:vsock_connect, data})

        # respond with OK
        :ok = :gen_tcp.send(client, "OK 1073741824\n")

        # now act as shell backdoor
        :inet.setopts(client, [{:packet, :line}])
        :ok = :gen_tcp.send(client, "Spawning backdoor root shell...\n")

        # handle one command
        {:ok, _cmd} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, Base.encode64("vsock works") <> "\n")
        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, "0\n")

        receive do
          :stop -> :ok
        end
      end)

      config = %{uds_path: uds_path, port: 1234}
      assert {:ok, socket} = Vsock.connect(config, 5000)

      # verify CONNECT protocol was sent
      assert_receive {:vsock_connect, data}, 1000
      assert data == "CONNECT 1234\n"

      # transport consumed the "Spawning..." ready message
      # socket should be in line mode and ready for shell protocol
      :ok = :gen_tcp.send(socket, "test\n")

      Vsock.close(socket)
      :gen_tcp.close(listen)
      File.rm(uds_path)
    end

    test "returns error when CONNECT is rejected" do
      uds_path = Path.join(System.tmp_dir!(), "vsock-reject-#{:rand.uniform(100_000)}.sock")
      File.rm(uds_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:active, false},
          {:ip, {:local, uds_path}}
        ])

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        {:ok, _data} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, "NO\n")
      end)

      config = %{uds_path: uds_path, port: 9999}
      assert {:error, {:vsock_connect_rejected, _}} = Vsock.connect(config, 5000)

      :gen_tcp.close(listen)
      File.rm(uds_path)
    end

    test "returns error when UDS does not exist" do
      config = %{uds_path: "/tmp/nonexistent-vsock-#{:rand.uniform(100_000)}.sock", port: 1234}
      assert {:error, _} = Vsock.connect(config, 500)
    end
  end

  describe "integration with Shell GenServer" do
    test "shell can execute commands over vsock transport" do
      uds_path = Path.join(System.tmp_dir!(), "vsock-shell-#{:rand.uniform(100_000)}.sock")
      File.rm(uds_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:active, false},
          {:ip, {:local, uds_path}}
        ])

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)

        # CONNECT handshake
        {:ok, _data} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, "OK 1073741824\n")

        # switch to line mode for shell protocol
        :inet.setopts(client, [{:packet, :line}])

        # shell backdoor ready
        :ok = :gen_tcp.send(client, "Spawning backdoor root shell...\n")

        # handle command
        {:ok, _cmd} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, Base.encode64("firecracker shell works") <> "\n")
        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, "0\n")

        receive do
          :stop -> :ok
        end
      end)

      {:ok, shell} =
        Shell.start_link(
          socket_path: uds_path,
          transport: Vsock,
          transport_config: %{uds_path: uds_path, port: 1234}
        )

      :ok = Shell.wait_for_connection(shell, 5000)
      assert {:ok, "firecracker shell works", 0} = Shell.execute(shell, "echo test")

      GenServer.stop(shell)
      :gen_tcp.close(listen)
      File.rm(uds_path)
    end
  end
end
