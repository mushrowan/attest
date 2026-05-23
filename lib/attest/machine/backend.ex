defmodule Attest.Machine.Backend do
  @moduledoc """
  Behaviour for VM backends

  Each backend owns the full boot sequence: process spawning, control plane
  connection, and shell setup. Machine delegates all backend-specific operations
  through this interface.

  Optional capabilities (screenshot, send_key) return `{:error, :unsupported}`
  when the backend doesn't support them.
  """

  @type config :: map()
  @type state :: term()

  # lifecycle
  @callback init(config) :: {:ok, state}
  @callback start(state) :: {:ok, shell_pid :: pid(), state} | {:error, term()}
  @callback shutdown(state, timeout()) :: :ok | {:error, term()}
  @callback halt(state, timeout()) :: :ok | {:error, term()}
  @callback wait_for_shutdown(state, timeout()) :: :ok | {:error, :timeout}
  @callback cleanup(state) :: :ok

  # optional capabilities -- return {:error, :unsupported} if not available
  @callback screenshot(state, filename :: String.t()) :: :ok | {:error, term()}
  @callback send_key(state, key :: String.t()) :: :ok | {:error, term()}
  @callback block(state) :: :ok | {:error, term()}
  @callback unblock(state) :: :ok | {:error, term()}
  @callback forward_port(state, host_port :: non_neg_integer(), guest_port :: non_neg_integer()) ::
              :ok | {:error, term()}
  @callback send_console(state, chars :: String.t()) :: :ok | {:error, term()}

  # snapshots -- return {:error, :unsupported} if not available
  @callback snapshot_create(state, snapshot_dir :: String.t()) :: :ok | {:error, term()}
  @callback snapshot_load(state, snapshot_dir :: String.t()) :: :ok | {:error, term()}
  @callback restore_from_snapshot(state, snapshot_dir :: String.t()) ::
              {:ok, shell_pid :: pid(), state} | {:error, term()}

  # port messages (called by Machine's handle_info)
  @callback handle_port_exit(state, exit_code :: non_neg_integer()) :: state

  # introspection
  @callback capabilities(state) :: [:screenshot | :send_key | :network_control | :port_forward]
  @callback timings(state) :: [map()]
  @optional_callbacks timings: 1

  # shared helpers for microVM backends

  @debug_boot_args "systemd.log_level=debug systemd.log_target=console"

  @doc """
  Resolve kernel boot args, appending systemd debug params if `debug_boot` is set
  """
  @spec resolve_boot_args(map(), String.t()) :: String.t()
  def resolve_boot_args(config, default_args) do
    args = Map.get(config, :kernel_boot_args, default_args)
    if Map.get(config, :debug_boot, false), do: args <> " " <> @debug_boot_args, else: args
  end

  @doc """
  Poll for a file to appear on disk
  """
  @spec wait_for_file(String.t(), timeout()) :: :ok | {:error, {:file_timeout, String.t()}}
  def wait_for_file(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_file(path, deadline)
  end

  @doc """
  Poll until a file is removed from disk
  """
  @spec wait_for_file_gone(String.t(), timeout()) :: :ok
  def wait_for_file_gone(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_file_gone(path, deadline)
  end

  @doc """
  Close a port safely, ignoring ArgumentError if already closed
  """
  @spec close_port(port() | nil) :: :ok
  def close_port(nil), do: :ok

  def close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Stop a shell GenServer if alive
  """
  @spec stop_shell(pid() | nil) :: :ok
  def stop_shell(nil), do: :ok

  def stop_shell(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Wait for a port process to exit
  """
  @spec wait_for_process_exit(port() | nil, boolean(), timeout()) :: :ok | {:error, :timeout}
  def wait_for_process_exit(nil, _exited, _timeout), do: :ok
  def wait_for_process_exit(_port, true, _timeout), do: :ok

  def wait_for_process_exit(port, _exited, timeout) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end

  defp poll_file(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, {:file_timeout, path}}
      else
        Process.sleep(50)
        poll_file(path, deadline)
      end
    end
  end

  defp poll_file_gone(path, deadline) do
    if File.exists?(path) do
      File.rm(path)

      if System.monotonic_time(:millisecond) >= deadline do
        :ok
      else
        Process.sleep(50)
        poll_file_gone(path, deadline)
      end
    else
      :ok
    end
  end

  @doc """
  Run a function and return `{duration_ms, metrics, result}`.
  """
  @spec timed((-> result)) :: {non_neg_integer(), map(), result} when result: var
  def timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    started_cpu_us = cpu_time_us()
    started_reductions = reductions()

    result = fun.()

    duration_ms = System.monotonic_time(:millisecond) - started_at
    cpu_us = max(cpu_time_us() - started_cpu_us, 0)
    reductions = max(reductions() - started_reductions, 0)

    {duration_ms, %{cpu_us: cpu_us, reductions: reductions}, result}
  end

  @doc """
  Build a timing entry.
  """
  @spec timing(atom(), non_neg_integer(), map(), map()) :: map()
  def timing(operation, duration_ms, metadata \\ %{}, metrics \\ %{}) do
    %{
      operation: operation,
      duration_ms: duration_ms,
      cpu_us: Map.get(metrics, :cpu_us, 0),
      reductions: Map.get(metrics, :reductions, 0),
      metadata: metadata
    }
  end

  @doc """
  Append a timing entry to backend state structs with a `:timings` field.
  """
  @spec record_timing(state, atom(), non_neg_integer(), map(), map()) :: state
  def record_timing(state, operation, duration_ms, metadata \\ %{}, metrics \\ %{}) do
    Map.update!(state, :timings, &[timing(operation, duration_ms, metadata, metrics) | &1])
  end

  defp cpu_time_us do
    {runtime_ms, _wall_clock_ms} = :erlang.statistics(:runtime)
    runtime_ms * 1000
  end

  defp reductions do
    {total, _since_last_call} = :erlang.statistics(:reductions)
    total
  end
end
