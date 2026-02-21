defmodule Attest.Machine.Shell.Transport.Vsock do
  @moduledoc """
  Vsock shell transport for firecracker

  Connects to firecracker's vsock UDS, sends the CONNECT protocol
  to establish a bidirectional stream to the guest's vsock listener,
  then switches to line mode for the shell command protocol.
  """

  @behaviour Attest.Machine.Shell.Transport

  require Logger

  @backdoor_ready "Spawning backdoor root shell..."

  @impl true
  def connect(config, timeout) do
    uds_path = Map.fetch!(config, :uds_path)
    port = Map.fetch!(config, :port)
    deadline = System.monotonic_time(:millisecond) + timeout

    connect_with_retry(uds_path, port, deadline)
  end

  # retry the full connect cycle — the vsock UDS appears when
  # firecracker starts but the guest listener isn't ready yet
  defp connect_with_retry(uds_path, port, deadline) do
    with {:ok, socket} <- connect_uds(uds_path, deadline),
         :ok <- send_connect(socket, port),
         :ok <- recv_ok(socket, remaining(deadline)),
         :ok <- wait_for_backdoor_ready(socket, remaining(deadline)) do
      Logger.info("vsock connected to port #{port}")
      {:ok, socket}
    else
      {:error, reason} when reason in [:closed, :econnrefused, :econnreset] ->
        if remaining(deadline) > 500 do
          Logger.debug("vsock connect attempt failed: #{inspect(reason)}, retrying...")
          Process.sleep(500)
          connect_with_retry(uds_path, port, deadline)
        else
          Logger.warning("vsock connect giving up after retries, last error: #{inspect(reason)}")
          {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("vsock connect failed with non-retryable error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp connect_uds(path, deadline) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}], remaining(deadline)) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :enoent} ->
        # UDS not yet created, retry
        if remaining(deadline) > 100 do
          Process.sleep(100)
          connect_uds(path, deadline)
        else
          {:error, :enoent}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_connect(socket, port) do
    :gen_tcp.send(socket, "CONNECT #{port}\n")
  end

  defp recv_ok(socket, timeout) do
    # temporarily use line mode to read exactly one response line
    :inet.setopts(socket, [{:packet, :line}])

    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        if String.starts_with?(String.trim(data), "OK") do
          :ok
        else
          :gen_tcp.close(socket)
          {:error, {:vsock_connect_rejected, String.trim(data)}}
        end

      {:error, reason} ->
        :gen_tcp.close(socket)
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
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
