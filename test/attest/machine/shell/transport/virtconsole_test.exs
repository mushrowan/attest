defmodule Attest.Machine.Shell.Transport.VirtConsoleTest do
  use ExUnit.Case, async: true

  require Logger

  alias Attest.Machine.Shell.Transport.VirtConsole

  defp wait_for_socket(path, retries \\ 50) do
    if File.exists?(path) do
      Logger.info("[mock-guest] socket file appeared: #{path}")
      :ok
    else
      if retries <= 0 do
        Logger.warning("[mock-guest] socket never appeared: #{path}")
        :timeout
      else
        Process.sleep(50)
        wait_for_socket(path, retries - 1)
      end
    end
  end

  describe "connect/2" do
    test "listens and accepts connection" do
      socket_path =
        Path.join(System.tmp_dir!(), "vc-test-#{:rand.uniform(10000)}.sock")

      File.rm(socket_path)
      Logger.info("[test] socket_path=#{socket_path} tmp_dir=#{System.tmp_dir!()}")

      test_pid = self()

      spawn(fn ->
        Logger.info("[mock-guest] waiting for socket file")
        wait_for_socket(socket_path)

        Logger.info("[mock-guest] connecting to #{socket_path}")

        case :gen_tcp.connect({:local, socket_path}, 0, [
               :binary,
               {:packet, :line},
               {:active, false}
             ]) do
          {:ok, sock} ->
            Logger.info("[mock-guest] connected, sending ready message")
            :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")
            send(test_pid, :guest_connected)

            receive do
              :stop -> :ok
            after
              5000 -> :ok
            end

          {:error, reason} ->
            Logger.error("[mock-guest] connect failed: #{inspect(reason)}")
            send(test_pid, {:guest_error, reason})
        end
      end)

      config = %{socket_path: socket_path}
      Logger.info("[test] calling VirtConsole.connect")
      assert {:ok, socket} = VirtConsole.connect(config, 15_000)
      Logger.info("[test] connect returned ok")
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
      assert {:error, :timeout} = VirtConsole.connect(config, 100)

      File.rm(socket_path)
    end
  end
end
