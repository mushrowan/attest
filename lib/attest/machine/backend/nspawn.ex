defmodule Attest.Machine.Backend.Nspawn do
  @moduledoc """
  systemd-nspawn backend for container-based testing

  Boots a NixOS system in a container using systemd-nspawn. No KVM
  or hardware virtualisation needed -- runs on any Linux host with
  systemd. ~25% faster than QEMU for simple tests and works in
  cheap VMs and CI environments without nested virtualisation.

  Shell connection uses a unix socket bind-mounted into the container
  at `/run/attest/shell.sock`. The container's backdoor service
  connects to it, reusing the VirtConsole transport.

  ## Capabilities

  No screenshots, keyboard simulation, or snapshots. Network
  isolation is available via `--private-network`.

  ## Config

  Required keys:
  - `:name` -- container/machine name
  - `:rootfs_path` -- path to the NixOS rootfs directory
  - `:state_dir` -- working directory for sockets and state

  Optional keys:
  - `:bind_dirs` -- list of {host_path, container_path} bind mounts (default: [])
  - `:nspawn_extra_args` -- extra command-line args for systemd-nspawn (default: [])
  """

  @behaviour Attest.Machine.Backend

  require Logger

  alias Attest.Machine.Backend
  alias Attest.Machine.Shell
  alias Attest.Machine.Shell.Transport.VirtConsole

  defstruct [
    :name,
    :rootfs_path,
    :state_dir,
    :shell_socket_path,
    :nspawn_port,
    :shell,
    :bind_dirs,
    :nspawn_extra_args,
    port_exited: false
  ]

  # lifecycle

  @impl true
  def init(config) do
    state_dir = Map.fetch!(config, :state_dir)

    {:ok,
     %__MODULE__{
       name: Map.get(config, :name, "unknown"),
       rootfs_path: Map.get(config, :rootfs_path),
       state_dir: state_dir,
       shell_socket_path: Path.join(state_dir, "shell.sock"),
       bind_dirs: Map.get(config, :bind_dirs, []),
       nspawn_extra_args: Map.get(config, :nspawn_extra_args, [])
     }}
  end

  @impl true
  def start(state) do
    File.mkdir_p!(state.state_dir)
    File.rm(state.shell_socket_path)

    # start shell listener before spawning container
    {:ok, shell} =
      Shell.start_link(
        socket_path: state.shell_socket_path,
        transport: VirtConsole,
        transport_config: %{socket_path: state.shell_socket_path}
      )

    # spawn nspawn process
    Logger.info("spawning nspawn container #{state.name}")

    port =
      Port.open({:spawn, nspawn_cmd(state)}, [:binary, :exit_status, :stderr_to_stdout])

    state = %{state | nspawn_port: port, shell: shell}

    # wait for container backdoor to connect
    case Shell.wait_for_connection(shell, 120_000) do
      :ok ->
        {:ok, shell, state}

      {:error, reason} ->
        Logger.error("shell connection failed for #{state.name}: #{inspect(reason)}")
        cleanup(state)
        {:error, reason}
    end
  end

  @impl true
  def shutdown(%{shell: nil} = state, _timeout) do
    halt(state, 5000)
  end

  def shutdown(%{shell: shell} = state, _timeout) do
    Logger.info("shutting down container #{state.name}")

    case Shell.execute(shell, "poweroff") do
      {:ok, _, _} -> :ok
      {:error, _} -> :ok
    end

    wait_for_process_exit(state, 30_000)
    cleanup(state)
    :ok
  end

  @impl true
  def halt(state, timeout) do
    Logger.info("halting container #{state.name}")

    # try machinectl terminate, fall back to closing port
    System.cmd("machinectl", ["terminate", state.name], stderr_to_stdout: true)

    case wait_for_process_exit(state, timeout) do
      :ok ->
        cleanup(state)
        :ok

      {:error, :timeout} ->
        Backend.close_port(state.nspawn_port)
        cleanup(state)
        :ok
    end
  end

  @impl true
  def wait_for_shutdown(state, timeout) do
    wait_for_process_exit(state, timeout)
  end

  @impl true
  def cleanup(state) do
    Backend.stop_shell(state.shell)
    Backend.close_port(state.nspawn_port)
    File.rm(state.shell_socket_path)
    :ok
  end

  # unsupported -- containers, no VGA, no snapshots

  @impl true
  def screenshot(_state, _filename), do: {:error, :unsupported}

  @impl true
  def send_key(_state, _key), do: {:error, :unsupported}

  @impl true
  def block(_state), do: {:error, :unsupported}

  @impl true
  def unblock(_state), do: {:error, :unsupported}

  @impl true
  def forward_port(_state, _host_port, _guest_port), do: {:error, :unsupported}

  @impl true
  def send_console(_state, _chars), do: {:error, :unsupported}

  @impl true
  def snapshot_create(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def snapshot_load(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def restore_from_snapshot(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def handle_port_exit(state, _code) do
    %{state | port_exited: true, nspawn_port: nil}
  end

  @impl true
  def capabilities(_state), do: []

  # public -- used by tests

  @doc """
  Build the systemd-nspawn command line
  """
  @spec nspawn_cmd(%__MODULE__{}) :: String.t()
  def nspawn_cmd(state) do
    base = [
      "systemd-nspawn",
      "--boot",
      "--directory=#{state.rootfs_path}",
      "--machine=#{state.name}",
      "--bind=#{state.state_dir}:/run/attest"
    ]

    binds =
      Enum.map(state.bind_dirs, fn {host, container} ->
        "--bind=#{host}:#{container}"
      end)

    args = base ++ binds ++ (state.nspawn_extra_args || [])
    Enum.join(args, " ")
  end

  # private

  defp wait_for_process_exit(state, timeout) do
    Backend.wait_for_process_exit(state.nspawn_port, state.port_exited, timeout)
  end
end
