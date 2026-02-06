defmodule NixosTest.Machine do
  @moduledoc """
  GenServer representing a single virtual machine

  Each Machine delegates backend-specific operations (process spawning,
  control plane, screenshots) to a Backend behaviour implementation.
  Shell-based operations (execute, wait_for_unit) stay in Machine.

  ## Backends

  - `Backend.QEMU` — Port.open, QMP, virtconsole shell
  - `Backend.Mock` — injected pids for unit tests
  """
  use GenServer

  require Logger

  alias NixosTest.Machine.Shell

  defstruct [
    :name,
    :shell,
    :backend_mod,
    :backend_state,
    booted: false,
    connected: false,
    callbacks: []
  ]

  # client API

  @doc """
  Start a Machine process

  ## Options

  - `:name` (required) — machine name
  - `:backend` — backend module (default: `Backend.QEMU`)
  - all other opts are passed to the backend's `init/1` as a map
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {NixosTest.MachineRegistry, name}}
    )
  end

  @doc """
  Start the VM
  """
  def start(machine) do
    GenServer.call(machine, :start, :infinity)
  end

  @doc """
  Check if the VM is booted
  """
  @spec booted?(GenServer.server()) :: boolean()
  def booted?(machine) do
    GenServer.call(machine, :booted?)
  end

  @doc """
  Stop the VM via QMP quit command (legacy, use halt/2 or shutdown/2)
  """
  def stop(machine) do
    GenServer.call(machine, :stop, 30_000)
  end

  @doc """
  Gracefully shutdown the VM via guest poweroff command
  """
  @spec shutdown(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def shutdown(machine, timeout \\ 60_000) do
    GenServer.call(machine, {:shutdown, timeout}, timeout + 5000)
  end

  @doc """
  Immediately halt the VM
  """
  @spec halt(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def halt(machine, timeout \\ 10_000) do
    GenServer.call(machine, {:halt, timeout}, timeout + 5000)
  end

  @doc """
  Wait for the VM process to exit
  """
  @spec wait_for_shutdown(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def wait_for_shutdown(machine, timeout \\ 60_000) do
    GenServer.call(machine, {:wait_for_shutdown, timeout}, timeout + 5000)
  end

  @doc """
  Execute a command in the VM and return {exit_code, output}
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
  Wait for a systemd unit to become active
  """
  def wait_for_unit(machine, unit, timeout \\ 900_000) do
    GenServer.call(machine, {:wait_for_unit, unit}, timeout)
  end

  @doc """
  Wait for a port to be open
  """
  def wait_for_open_port(machine, port, timeout \\ 900_000) do
    GenServer.call(machine, {:wait_for_open_port, port}, timeout)
  end

  @doc """
  Take a screenshot
  """
  def screenshot(machine, filename) do
    GenServer.call(machine, {:screenshot, filename})
  end

  # server callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    backend_mod = Keyword.get(opts, :backend, NixosTest.Machine.Backend.QEMU)

    # build config map from opts for the backend
    config =
      opts
      |> Keyword.drop([:backend, :callbacks])
      |> Map.new()

    {:ok, backend_state} = backend_mod.init(config)

    state = %__MODULE__{
      name: name,
      backend_mod: backend_mod,
      backend_state: backend_state,
      callbacks: Keyword.get(opts, :callbacks, [])
    }

    Logger.info("machine #{state.name} initialized")
    {:ok, state}
  end

  @impl true
  def handle_call(:start, _from, state) do
    Logger.info("starting machine #{state.name}")

    {:ok, shell_pid, backend_state} = state.backend_mod.start(state.backend_state)

    state = %{
      state
      | backend_state: backend_state,
        shell: shell_pid,
        booted: true,
        connected: shell_pid != nil
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:booted?, _from, state) do
    {:reply, state.booted, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Logger.info("stopping machine #{state.name}")
    state.backend_mod.halt(state.backend_state, 10_000)
    {:reply, :ok, %{state | booted: false, connected: false, shell: nil}}
  end

  @impl true
  def handle_call({:shutdown, timeout}, _from, state) do
    Logger.info("shutting down machine #{state.name}")
    result = state.backend_mod.shutdown(state.backend_state, timeout)
    {:reply, result, %{state | booted: false, connected: false, shell: nil}}
  end

  @impl true
  def handle_call({:halt, timeout}, _from, state) do
    Logger.info("halting machine #{state.name}")
    result = state.backend_mod.halt(state.backend_state, timeout)
    {:reply, result, %{state | booted: false, connected: false, shell: nil}}
  end

  @impl true
  def handle_call({:wait_for_shutdown, timeout}, _from, state) do
    result = state.backend_mod.wait_for_shutdown(state.backend_state, timeout)
    {:reply, result, state}
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
  def handle_call({:screenshot, filename}, _from, state) do
    Logger.info("taking screenshot: #{filename}")

    case state.backend_mod.screenshot(state.backend_state, filename) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> raise "screenshot failed: #{inspect(reason)}"
    end
  end

  # port stdout/stderr data from QEMU backend (port owner is Machine process)
  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    truncated = String.slice(to_string(data), 0, 200)
    Logger.info("QEMU[#{state.name}]: #{truncated}")
    {:noreply, state}
  end

  # exit_status: update backend state so it knows the process exited
  def handle_info({port, {:exit_status, code}}, state) when is_port(port) do
    Logger.warning("process exited with code #{code}")
    backend_state = state.backend_mod.handle_port_exit(state.backend_state, code)
    {:noreply, %{state | booted: false, connected: false, backend_state: backend_state}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("machine #{state.name} terminating: #{inspect(reason)}")
    state.backend_mod.cleanup(state.backend_state)
    :ok
  end

  # private helpers

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
