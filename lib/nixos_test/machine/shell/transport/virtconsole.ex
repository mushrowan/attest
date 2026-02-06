defmodule NixosTest.Machine.Shell.Transport.VirtConsole do
  @moduledoc """
  VirtConsole shell transport

  Listens on a unix socket, accepts a connection from the guest's
  virtconsole device, and waits for the "Spawning backdoor root shell..."
  ready message. Used by QEMU and cloud-hypervisor backends.
  """

  @behaviour NixosTest.Machine.Shell.Transport

  require Logger

  @backdoor_ready "Spawning backdoor root shell..."

  @impl true
  def connect(config, timeout) do
    socket_path = Map.fetch!(config, :socket_path)
    File.rm(socket_path)

    case :gen_tcp.listen(0, [
           :binary,
           {:packet, :line},
           {:active, false},
           {:ip, {:local, socket_path}}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("shell listening on #{socket_path}")

        case :gen_tcp.accept(listen_socket, timeout) do
          {:ok, socket} ->
            case wait_for_backdoor_ready(socket, timeout) do
              :ok ->
                Logger.info("shell backdoor connected")
                # close listen socket, we only need the accepted connection
                :gen_tcp.close(listen_socket)
                {:ok, socket}

              {:error, reason} ->
                :gen_tcp.close(socket)
                :gen_tcp.close(listen_socket)
                {:error, reason}
            end

          {:error, reason} ->
            :gen_tcp.close(listen_socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp wait_for_backdoor_ready(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        if String.contains?(line, @backdoor_ready) do
          :ok
        else
          wait_for_backdoor_ready(socket, timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
