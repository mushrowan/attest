defmodule NixosTest.Machine do
  @moduledoc """
  GenServer representing a single QEMU virtual machine.

  Each Machine process:
  - Owns and controls a QEMU process
  - Communicates via QMP (QEMU Machine Protocol) for control
  - Uses virtconsole shell "backdoor" for command execution
  - Handles VM lifecycle (boot, shutdown, reboot)

  ## State

  The machine maintains:
  - QEMU process (port)
  - QMP socket connection
  - Shell socket connection
  - Boot/connection status
  """
  use GenServer

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
    :booted,
    :connected,
    :callbacks
  ]

  # client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {NixosTest.MachineRegistry, name}}
    )
  end

  @doc """
  Start the VM.
  """
  def start(machine) do
    GenServer.call(machine, :start, :infinity)
  end

  @doc """
  Check if the VM is booted.
  """
  @spec booted?(GenServer.server()) :: boolean()
  def booted?(machine) do
    GenServer.call(machine, :booted?)
  end

  @doc """
  Stop the VM.
  """
  def stop(machine) do
    GenServer.call(machine, :stop, 30_000)
  end

  @doc """
  Execute a command in the VM and return {exit_code, output}.
  """
  def execute(machine, command, timeout \\ 900_000) do
    GenServer.call(machine, {:execute, command}, timeout)
  end

  @doc """
  Execute a command and expect success (exit code 0).
  Raises on non-zero exit.
  """
  def succeed(machine, command) do
    case execute(machine, command) do
      {0, output} ->
        output

      {code, output} ->
        raise "command failed with exit code #{code}: #{output}"
    end
  end

  @doc """
  Execute a command and expect failure (non-zero exit code).
  Raises on zero exit.
  """
  def fail(machine, command) do
    case execute(machine, command) do
      {0, output} ->
        raise "command unexpectedly succeeded: #{output}"

      {_code, output} ->
        output
    end
  end

  @doc """
  Wait for a systemd unit to become active.
  """
  def wait_for_unit(machine, unit, timeout \\ 900_000) do
    GenServer.call(machine, {:wait_for_unit, unit}, timeout)
  end

  @doc """
  Wait for a port to be open.
  """
  def wait_for_open_port(machine, port, timeout \\ 900_000) do
    GenServer.call(machine, {:wait_for_open_port, port}, timeout)
  end

  @doc """
  Take a screenshot.
  """
  def screenshot(machine, filename) do
    GenServer.call(machine, {:screenshot, filename})
  end

  # server callbacks

  @impl true
  def init(opts) do
    # allow injecting QMP/Shell for testing
    qmp = Keyword.get(opts, :qmp)
    shell = Keyword.get(opts, :shell)
    connected = qmp != nil or shell != nil

    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      start_command: Keyword.get(opts, :start_command),
      qmp_socket_path: Keyword.get(opts, :qmp_socket_path),
      shell_socket_path: Keyword.get(opts, :shell_socket_path),
      state_dir: Keyword.get(opts, :state_dir),
      shared_dir: Keyword.get(opts, :shared_dir),
      qmp: qmp,
      shell: shell,
      booted: connected,
      connected: connected,
      callbacks: Keyword.get(opts, :callbacks, [])
    }

    Logger.info("machine #{state.name} initialized")
    {:ok, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    Logger.info("starting machine #{state.name}")

    # spawn QEMU process if start_command provided
    state =
      if state.start_command do
        port =
          Port.open({:spawn, state.start_command}, [:binary, :exit_status, :stderr_to_stdout])

        Logger.debug("spawned process for #{state.name}")
        %{state | qemu_port: port}
      else
        state
      end

    # create shell listener and wait for connection if path provided
    state =
      if state.shell_socket_path do
        connect_shell(state, state.shell_socket_path)
      else
        state
      end

    # connect to QMP socket if path provided
    state =
      if state.qmp_socket_path do
        connect_qmp(state, state.qmp_socket_path)
      else
        state
      end

    {:reply, :ok, %{state | booted: true}}
  end

  @impl true
  def handle_call(:booted?, _from, state) do
    {:reply, state.booted, state}
  end

  @impl true
  def handle_call(:stop, _from, %{qmp: nil} = state) do
    Logger.info("stopping machine #{state.name} (no QMP)")
    {:reply, :ok, %{state | booted: false, connected: false}}
  end

  def handle_call(:stop, _from, %{qmp: qmp} = state) do
    Logger.info("stopping machine #{state.name}")
    {:ok, _} = QMP.command(qmp, "quit")
    {:reply, :ok, %{state | booted: false, connected: false, qmp: nil, shell: nil}}
  end

  @impl true
  def handle_call({:execute, _command}, _from, %{shell: nil} = state) do
    Logger.debug("executing on #{state.name}: not connected")
    raise "cannot execute: machine #{state.name} not connected"
  end

  def handle_call({:execute, command}, _from, %{shell: shell} = state) do
    Logger.debug("executing on #{state.name}: #{command}")
    {:ok, output, exit_code} = Shell.execute(shell, command)
    {:reply, {exit_code, output}, state}
  end

  @impl true
  def handle_call({:wait_for_unit, unit}, _from, %{shell: shell} = state) do
    Logger.info("waiting for unit #{unit} on #{state.name}")
    result = poll_unit_state(shell, unit)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:wait_for_open_port, port}, _from, %{shell: shell} = state) do
    Logger.info("waiting for port #{port} on #{state.name}")
    result = poll_port_open(shell, port)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:screenshot, _filename}, _from, %{qmp: nil} = state) do
    Logger.debug("screenshot on #{state.name}: not connected")
    raise "cannot take screenshot: machine #{state.name} not connected"
  end

  def handle_call({:screenshot, filename}, _from, %{qmp: qmp} = state) do
    Logger.info("taking screenshot: #{filename}")
    {:ok, _} = QMP.command(qmp, "screendump", %{"filename" => filename})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{qemu_port: port} = state) do
    Logger.warning("QEMU process exited with code #{code}")
    {:noreply, %{state | booted: false, connected: false, qemu_port: nil}}
  end

  def handle_info({port, {:data, data}}, %{qemu_port: port} = state) do
    Logger.debug("QEMU output: #{inspect(data)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("machine #{state.name} terminating: #{inspect(reason)}")

    # cleanup QEMU process if running
    if state.qemu_port do
      try do
        Port.close(state.qemu_port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # Private helpers

  defp connect_qmp(state, socket_path, retries \\ 10) do
    Logger.debug("connecting to QMP at #{socket_path}")

    if File.exists?(socket_path) do
      {:ok, qmp} = QMP.start_link(socket_path: socket_path)
      %{state | qmp: qmp, connected: true}
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

  defp connect_shell(state, socket_path) do
    Logger.debug("waiting for shell connection at #{socket_path}")
    {:ok, shell} = Shell.start_link(socket_path: socket_path)
    :ok = Shell.wait_for_connection(shell)
    %{state | shell: shell, connected: true}
  end

  defp poll_unit_state(shell, unit, retries \\ 60) do
    cmd = "systemctl show #{unit} --property=ActiveState"
    {:ok, output, _exit_code} = Shell.execute(shell, cmd)

    case parse_unit_state(output) do
      "active" ->
        :ok

      "failed" ->
        raise "unit #{unit} reached state failed"

      _other when retries > 0 ->
        Process.sleep(1000)
        poll_unit_state(shell, unit, retries - 1)

      other ->
        raise "unit #{unit} did not become active (last state: #{other})"
    end
  end

  defp parse_unit_state(output) do
    case Regex.run(~r/ActiveState=(\w+)/, output) do
      [_, state] -> state
      _ -> "unknown"
    end
  end

  defp poll_port_open(shell, port, retries \\ 60) do
    cmd = "nc -z localhost #{port}"
    {:ok, _output, exit_code} = Shell.execute(shell, cmd)

    case exit_code do
      0 ->
        :ok

      _other when retries > 0 ->
        Process.sleep(1000)
        poll_port_open(shell, port, retries - 1)

      _other ->
        raise "port #{port} did not open"
    end
  end
end
