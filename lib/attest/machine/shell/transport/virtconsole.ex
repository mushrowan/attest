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
    case connect_with_milestones(config, timeout) do
      {:ok, socket, _milestones} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Connect to the guest shell and return boot milestones measured from the
  socket listener being created.
  """
  @spec connect_with_milestones(map(), timeout()) ::
          {:ok, port(), map()} | {:error, term()}
  def connect_with_milestones(config, timeout) do
    socket_path = Map.fetch!(config, :socket_path)
    File.rm(socket_path)
    started_at = System.monotonic_time(:millisecond)

    with {:ok, listen_socket} <-
           :gen_tcp.listen(0, [
             :binary,
             {:packet, :line},
             {:active, false},
             {:ip, {:local, socket_path}}
           ]),
         _ = Logger.debug("shell listening on #{socket_path}"),
         {:ok, socket} <- accept_or_close(listen_socket, timeout),
         guest_connected_ms = elapsed_ms(started_at),
         {:ok, milestones} <-
           wait_or_close(socket, listen_socket, timeout, started_at, guest_connected_ms) do
      Logger.debug("shell backdoor connected")
      :gen_tcp.close(listen_socket)
      {:ok, socket, milestones}
    end
  end

  @impl true
  def send(socket, data), do: :gen_tcp.send(socket, data)

  @impl true
  def recv(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

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

  defp wait_or_close(socket, listen_socket, timeout, started_at, guest_connected_ms) do
    case wait_for_backdoor_ready(socket, timeout, started_at, nil) do
      {:ok, milestones} ->
        {:ok, Map.put(milestones, :guest_connected_ms, guest_connected_ms)}

      {:error, reason} ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        {:error, reason}
    end
  end

  defp wait_for_backdoor_ready(socket, timeout, started_at, first_output_ms) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        first_output_ms = first_output_ms || elapsed_ms(started_at)

        if String.contains?(line, @backdoor_ready) do
          {:ok,
           %{
             first_output_ms: first_output_ms,
             backdoor_ready_ms: elapsed_ms(started_at)
           }}
        else
          wait_for_backdoor_ready(socket, timeout, started_at, first_output_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
