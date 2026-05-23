defmodule Attest.Machine.Backend.SSH do
  @moduledoc """
  SSH backend for remote hosts

  Connects to an already-running host over SSH and runs commands
  via the shell protocol. No hypervisor management -- useful for
  cloud VMs, physical machines, or containers with sshd.

  ## Capabilities

  No screenshots, keyboard simulation, snapshots, or network control.
  Only shell command execution is supported.

  ## Config

  Required keys:
  - `:host` -- hostname or IP address

  Optional keys:
  - `:name` -- machine name (default: "unknown")
  - `:port` -- SSH port (default: 22)
  - `:user` -- SSH username (default: "root")
  - `:password` -- password for authentication
  - `:user_dir` -- path to directory containing user keys (id_rsa etc)
  """

  @behaviour Attest.Machine.Backend

  require Logger

  alias Attest.Machine.Backend
  alias Attest.Machine.Shell
  alias Attest.Machine.Shell.Transport

  defstruct [
    :name,
    :host,
    :port,
    :user,
    :password,
    :user_dir,
    :mode,
    :shell,
    connected: false
  ]

  # lifecycle

  @impl true
  def init(config) do
    {:ok,
     %__MODULE__{
       name: Map.get(config, :name, "unknown"),
       host: Map.get(config, :host),
       port: Map.get(config, :port, 22),
       user: Map.get(config, :user, "root"),
       password: Map.get(config, :password),
       user_dir: Map.get(config, :user_dir),
       mode: Map.get(config, :mode)
     }}
  end

  @impl true
  def start(state) do
    transport_config = build_transport_config(state)

    Logger.info("connecting to #{state.name} via SSH (#{state.host}:#{state.port})")

    {:ok, shell} =
      Shell.start_link(
        socket_path: "ssh://#{state.host}:#{state.port}",
        transport: Transport.SSH,
        transport_config: transport_config
      )

    case Shell.wait_for_connection(shell, 30_000) do
      :ok ->
        {:ok, shell, %{state | shell: shell, connected: true}}

      {:error, reason} ->
        GenServer.stop(shell)
        {:error, reason}
    end
  end

  @impl true
  def shutdown(%{shell: nil} = state, _timeout) do
    cleanup(state)
    :ok
  end

  def shutdown(%{shell: shell} = state, _timeout) do
    Logger.info("shutting down #{state.name} via SSH")

    task = Task.async(fn -> Shell.execute(shell, "poweroff") end)

    if Task.yield(task, 5_000) == nil do
      Task.shutdown(task, :brutal_kill)
    end

    if Process.alive?(shell) do
      Process.exit(shell, :kill)
    end

    cleanup(state)
    :ok
  end

  @impl true
  def halt(state, _timeout) do
    Logger.info("halting #{state.name} (closing SSH connection)")
    cleanup(state)
    :ok
  end

  @impl true
  def wait_for_shutdown(_state, _timeout), do: :ok

  @impl true
  def cleanup(state) do
    Backend.stop_shell(state.shell)
    :ok
  end

  # unsupported -- no hypervisor, no VGA, no snapshots

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
  def handle_port_exit(state, _code), do: state

  @impl true
  def capabilities(_state), do: []

  # private

  defp build_transport_config(state) do
    config = %{
      host: state.host,
      port: state.port,
      user: state.user
    }

    config = if state.password, do: Map.put(config, :password, state.password), else: config
    config = if state.user_dir, do: Map.put(config, :user_dir, state.user_dir), else: config
    config = if Map.get(state, :mode), do: Map.put(config, :mode, state.mode), else: config
    config
  end
end
