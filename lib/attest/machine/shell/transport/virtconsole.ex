defmodule Attest.Machine.Shell.Transport.VirtConsole do
  @moduledoc """
  VirtConsole shell transport

  Listens on a unix socket, accepts a connection from the guest's
  virtconsole device, and waits for the "Spawning backdoor root shell..."
  ready message. Used by QEMU and cloud-hypervisor backends.
  """

  @behaviour Attest.Machine.Shell.Transport

  require Logger

  @backdoor_ready "Spawning backdoor root shell..."

  @impl true
  def connect(config, timeout) do
    socket_path = Map.fetch!(config, :socket_path)
    File.rm(socket_path)

    with {:ok, listen_socket} <-
           :gen_tcp.listen(0, [
             :binary,
             {:packet, :line},
             {:active, false},
             {:ip, {:local, socket_path}}
           ]),
         _ = Logger.info("shell listening on #{socket_path}"),
         {:ok, socket} <- accept_or_close(listen_socket, timeout),
         :ok <- wait_or_close(socket, listen_socket, timeout) do
      Logger.info("shell backdoor connected")
      :gen_tcp.close(listen_socket)
      {:ok, socket}
    end
  end

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp accept_or_close(listen_socket, timeout) do
    case :gen_tcp.accept(listen_socket, timeout) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        :gen_tcp.close(listen_socket)
        {:error, reason}
    end
  end

  defp wait_or_close(socket, listen_socket, timeout) do
    case wait_for_backdoor_ready(socket, timeout) do
      :ok ->
        :ok

      {:error, reason} ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        {:error, reason}
    end
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
