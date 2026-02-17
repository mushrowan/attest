defmodule Attest.Machine.Shell.Transport.VirtConsoleTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.Shell.Transport.VirtConsole

  describe "connect/2" do
    test "listens and accepts connection" do
      socket_path =
        Path.join(System.tmp_dir!(), "vc-test-#{:rand.uniform(10000)}.sock")

      File.rm(socket_path)

      test_pid = self()

      # simulate guest connecting
      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [
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

      config = %{socket_path: socket_path}
      assert {:ok, socket} = VirtConsole.connect(config, 5000)
      assert is_port(socket)
      assert_receive :guest_connected, 2000

      VirtConsole.close(socket)
      File.rm(socket_path)
    end

    test "returns error on timeout" do
      socket_path =
        Path.join(System.tmp_dir!(), "vc-timeout-#{:rand.uniform(10000)}.sock")

      File.rm(socket_path)

      config = %{socket_path: socket_path}
      # nobody connects, should timeout
      assert {:error, :timeout} = VirtConsole.connect(config, 100)

      File.rm(socket_path)
    end
  end
end
