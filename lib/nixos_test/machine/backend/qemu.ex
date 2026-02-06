defmodule NixosTest.Machine.Backend.QEMU do
  @moduledoc """
  QEMU backend

  Manages the full QEMU lifecycle: process spawning via Port.open,
  QMP control plane connection, and virtconsole shell setup.
  """

  @behaviour NixosTest.Machine.Backend

  require Logger

  alias NixosTest.Machine.{QMP, Shell}

  defstruct [
    :name,
    :start_command,
    :qmp_socket_path,
    :shell_socket_path,
    :state_dir,
    :shared_dir,
    :qemu_port,
    :qmp,
    :shell,
    port_exited: false
  ]

  @impl true
  def init(config) do
    {:ok,
     %__MODULE__{
       name: Map.get(config, :name, "unknown"),
       start_command: Map.get(config, :start_command),
       qmp_socket_path: Map.get(config, :qmp_socket_path),
       shell_socket_path: Map.get(config, :shell_socket_path),
       state_dir: Map.get(config, :state_dir),
       shared_dir: Map.get(config, :shared_dir)
     }}
  end

  @impl true
  def start(state) do
    # create shell listener FIRST (before QEMU starts, so it can connect)
    {shell_pid, state} =
      if state.shell_socket_path do
        {:ok, shell} = Shell.start_link(socket_path: state.shell_socket_path)
        {shell, %{state | shell: shell}}
      else
        {nil, state}
      end

    # spawn QEMU process if start_command provided
    state =
      if state.start_command do
        Logger.info("spawning QEMU for #{state.name}")

        port =
          Port.open({:spawn, state.start_command}, [:binary, :exit_status, :stderr_to_stdout])

        %{state | qemu_port: port}
      else
        state
      end

    # wait for shell connection if we created a listener
    if shell_pid do
      Logger.info("waiting for shell connection on #{state.name}")
      :ok = Shell.wait_for_connection(shell_pid, 120_000)
    end

    # connect to QMP socket if path provided
    state =
      if state.qmp_socket_path do
        connect_qmp(state, state.qmp_socket_path)
      else
        state
      end

    {:ok, shell_pid, state}
  end

  @impl true
  def shutdown(%{shell: nil} = state, timeout) do
    Logger.warning("shutdown on #{state.name}: no shell, using halt")
    halt(state, timeout)
  end

  def shutdown(%{shell: shell} = state, timeout) do
    Logger.info("shutting down #{state.name}")

    case Shell.execute(shell, "poweroff") do
      {:ok, _, _} -> :ok
      {:error, :closed} -> :ok
      {:error, _reason} -> :ok
    end

    result = wait_for_process_exit(state, timeout)
    cleanup(state)
    result
  end

  @impl true
  def halt(state, timeout) do
    Logger.info("halting #{state.name}")

    if state.qmp do
      QMP.command(state.qmp, "quit")
    end

    result = wait_for_process_exit(state, timeout)
    cleanup(state)
    result
  end

  @impl true
  def wait_for_shutdown(state, timeout) do
    wait_for_process_exit(state, timeout)
  end

  @impl true
  def cleanup(state) do
    if state.qmp && Process.alive?(state.qmp) do
      GenServer.stop(state.qmp, :normal)
    end

    if state.shell && Process.alive?(state.shell) do
      GenServer.stop(state.shell, :normal)
    end

    if state.qemu_port do
      try do
        Port.close(state.qemu_port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @impl true
  def screenshot(%{qmp: nil}, _filename) do
    {:error, :unsupported}
  end

  def screenshot(%{qmp: qmp}, filename) do
    Logger.info("taking screenshot: #{filename}")

    case QMP.command(qmp, "screendump", %{"filename" => filename}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_key(%{qmp: nil}, _key), do: {:error, :unsupported}

  def send_key(%{qmp: qmp}, key) do
    keys =
      key
      |> String.split("-")
      |> Enum.map(fn k -> %{"type" => "qcode", "data" => k} end)

    case QMP.command(qmp, "send-key", %{"keys" => keys}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def block(%{qmp: nil}), do: {:error, :unsupported}

  def block(%{qmp: qmp}) do
    case QMP.command(qmp, "set_link", %{"name" => "virtio-net-pci.1", "up" => false}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def unblock(%{qmp: nil}), do: {:error, :unsupported}

  def unblock(%{qmp: qmp}) do
    case QMP.command(qmp, "set_link", %{"name" => "virtio-net-pci.1", "up" => true}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def forward_port(%{qmp: nil}, _host_port, _guest_port), do: {:error, :unsupported}

  def forward_port(%{qmp: qmp}, host_port, guest_port) do
    cmd = "hostfwd_add tcp::#{host_port}-:#{guest_port}"

    case QMP.command(qmp, "human-monitor-command", %{"command-line" => cmd}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_port_exit(state, _code) do
    %{state | port_exited: true, qemu_port: nil}
  end

  @impl true
  def capabilities(_state), do: [:screenshot, :send_key, :network_control, :port_forward]

  # private helpers

  defp connect_qmp(state, socket_path, retries \\ 10) do
    Logger.debug("connecting to QMP at #{socket_path}")

    if File.exists?(socket_path) do
      {:ok, qmp} = QMP.start_link(socket_path: socket_path)
      %{state | qmp: qmp}
    else
      if retries > 0 do
        Logger.debug("QMP socket not ready, retrying in 100ms (#{retries} left)")
        Process.sleep(100)
        connect_qmp(state, socket_path, retries - 1)
      else
        raise "QMP socket #{socket_path} not found after retries"
      end
    end
  end

  defp wait_for_process_exit(%{qemu_port: nil}, _timeout), do: :ok
  defp wait_for_process_exit(%{port_exited: true}, _timeout), do: :ok

  defp wait_for_process_exit(%{qemu_port: port}, timeout) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end
end
