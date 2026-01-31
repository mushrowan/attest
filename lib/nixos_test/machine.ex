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

  defstruct [
    :name,
    :start_command,
    :state_dir,
    :shared_dir,
    :qemu_port,
    :qmp_socket,
    :shell_socket,
    :monitor_socket,
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
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      start_command: Keyword.get(opts, :start_command),
      state_dir: Keyword.get(opts, :state_dir),
      shared_dir: Keyword.get(opts, :shared_dir),
      booted: false,
      connected: false,
      callbacks: Keyword.get(opts, :callbacks, [])
    }

    Logger.info("machine #{state.name} initialized")
    {:ok, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    Logger.info("starting machine #{state.name}")

    # TODO: actually start QEMU
    # 1. spawn QEMU process with appropriate args
    # 2. connect to QMP socket
    # 3. connect to shell socket (virtconsole)
    # 4. wait for boot

    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Logger.info("stopping machine #{state.name}")

    # TODO: graceful shutdown via QMP

    {:reply, :ok, %{state | booted: false, connected: false}}
  end

  @impl true
  def handle_call({:execute, command}, _from, state) do
    Logger.debug("executing on #{state.name}: #{command}")

    # TODO: send command via shell socket
    # protocol: send "( <command> ); echo '|!=EOF' $?\n"
    # receive output until "|!=EOF <exit_code>\n"

    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call({:wait_for_unit, unit}, _from, state) do
    Logger.info("waiting for unit #{unit} on #{state.name}")

    # TODO: poll systemctl until unit is active
    # retry with backoff until timeout

    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call({:wait_for_open_port, port}, _from, state) do
    Logger.info("waiting for port #{port} on #{state.name}")

    # TODO: poll until port is open

    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call({:screenshot, filename}, _from, state) do
    Logger.info("taking screenshot: #{filename}")

    # TODO: use QMP screendump command

    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{qemu_port: port} = state) do
    Logger.warning("QEMU process exited: #{inspect(reason)}")
    {:noreply, %{state | booted: false, connected: false, qemu_port: nil}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("machine #{state.name} terminating: #{inspect(reason)}")

    # cleanup QEMU process if running
    if state.qemu_port do
      Port.close(state.qemu_port)
    end

    :ok
  end
end
