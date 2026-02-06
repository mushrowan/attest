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

  @type execute_result :: {non_neg_integer(), String.t()} | {:error, term()}

  @doc """
  Start a Machine process

  ## Options

  - `:name` (required) — machine name
  - `:backend` — backend module (default: `Backend.QEMU`)
  - all other opts are passed to the backend's `init/1` as a map
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {NixosTest.MachineRegistry, name}}
    )
  end

  @doc """
  Start the VM
  """
  @spec start(GenServer.server()) :: :ok
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
  @spec stop(GenServer.server()) :: :ok
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
  @spec execute(GenServer.server(), String.t(), timeout()) :: execute_result()
  def execute(machine, command, timeout \\ 900_000) do
    GenServer.call(machine, {:execute, command}, timeout)
  end

  @doc """
  Execute a command and expect success (exit code 0).
  Raises on non-zero exit.
  """
  @spec succeed(GenServer.server(), String.t()) :: String.t()
  def succeed(machine, command) do
    case execute(machine, command) do
      {0, output} ->
        output

      {code, output} when is_integer(code) ->
        raise "command failed with exit code #{code}: #{output}"

      {:error, reason} ->
        raise "command failed: #{inspect(reason)}"
    end
  end

  @doc """
  Execute a command and expect failure (non-zero exit code).
  Raises on zero exit.
  """
  @spec fail(GenServer.server(), String.t()) :: String.t()
  def fail(machine, command) do
    case execute(machine, command) do
      {0, output} ->
        raise "command unexpectedly succeeded: #{output}"

      {code, output} when is_integer(code) ->
        output

      {:error, reason} ->
        raise "command failed: #{inspect(reason)}"
    end
  end

  @doc """
  Wait for a systemd unit to become active
  """
  @spec wait_for_unit(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def wait_for_unit(machine, unit, timeout \\ 900_000) do
    GenServer.call(machine, {:wait_for_unit, unit, timeout}, timeout + 5000)
  end

  @doc """
  Wait for a port to be open
  """
  @spec wait_for_open_port(GenServer.server(), non_neg_integer(), timeout()) ::
          :ok | {:error, term()}
  def wait_for_open_port(machine, port, timeout \\ 900_000) do
    GenServer.call(machine, {:wait_for_open_port, port, timeout}, timeout + 5000)
  end

  @doc """
  Take a screenshot
  """
  @spec screenshot(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def screenshot(machine, filename) do
    GenServer.call(machine, {:screenshot, filename})
  end

  @doc """
  Send a key combination to the VM (e.g. "ctrl-alt-delete", "ret")
  """
  @spec send_key(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_key(machine, key) do
    GenServer.call(machine, {:send_key, key})
  end

  @doc """
  Type a string of characters on the virtual keyboard

  Each character is mapped to the appropriate key combo and sent
  individually with an optional delay between keys (default 10ms).
  """
  @spec send_chars(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_chars(machine, chars, opts \\ []) do
    delay = Keyword.get(opts, :delay, 10)

    chars
    |> String.graphemes()
    |> Enum.reduce_while(:ok, fn char, :ok ->
      send_char(machine, char, delay)
    end)
  end

  defp send_char(machine, char, delay) do
    case send_key(machine, char_to_key(char)) do
      :ok ->
        if delay > 0, do: Process.sleep(delay)
        {:cont, :ok}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  @doc """
  Map a single character to a QMP key name

  Handles lowercase letters, digits, uppercase (shift+letter),
  and common special characters.
  """
  @spec char_to_key(String.t()) :: String.t()
  def char_to_key(char) when byte_size(char) == 1 do
    Map.get(char_key_map(), char, char)
  end

  def char_to_key(char), do: char

  @special_keys %{
    "\n" => "ret",
    "\t" => "tab",
    " " => "spc",
    "-" => "0x0C",
    "=" => "0x0D",
    "[" => "0x1A",
    "]" => "0x1B",
    ";" => "0x27",
    "'" => "0x28",
    "`" => "0x29",
    "\\" => "0x2B",
    "," => "0x33",
    "." => "0x34",
    "/" => "0x35",
    # shifted variants
    "_" => "shift-0x0C",
    "+" => "shift-0x0D",
    "{" => "shift-0x1A",
    "}" => "shift-0x1B",
    ":" => "shift-0x27",
    "\"" => "shift-0x28",
    "~" => "shift-0x29",
    "|" => "shift-0x2B",
    "<" => "shift-0x33",
    ">" => "shift-0x34",
    "?" => "shift-0x35",
    "!" => "shift-0x02",
    "@" => "shift-0x03",
    "#" => "shift-0x04",
    "$" => "shift-0x05",
    "%" => "shift-0x06",
    "^" => "shift-0x07",
    "&" => "shift-0x08",
    "*" => "shift-0x09",
    "(" => "shift-0x0A",
    ")" => "shift-0x0B"
  }

  defp char_key_map do
    # uppercase letters → shift+lowercase
    uppers =
      for c <- ?A..?Z, into: %{} do
        {<<c>>, "shift-#{<<c + 32>>}"}
      end

    Map.merge(uppers, @special_keys)
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
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:execute, command}, _from, %{shell: shell} = state) do
    Logger.debug("executing on #{state.name}: #{command}")

    case Shell.execute(shell, command) do
      {:ok, output, exit_code} -> {:reply, {exit_code, output}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:wait_for_unit, unit, timeout}, _from, %{shell: shell} = state) do
    Logger.info("waiting for unit #{unit} on #{state.name}")
    retries = max(div(timeout, 1000), 1)
    result = poll_unit_state(shell, unit, retries)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:wait_for_open_port, port, timeout}, _from, %{shell: shell} = state) do
    Logger.info("waiting for port #{port} on #{state.name}")
    retries = max(div(timeout, 1000), 1)
    result = poll_port_open(shell, port, retries)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:screenshot, filename}, _from, state) do
    Logger.info("taking screenshot: #{filename}")
    result = state.backend_mod.screenshot(state.backend_state, filename)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:send_key, key}, _from, state) do
    Logger.info("sending key #{key} to #{state.name}")
    result = state.backend_mod.send_key(state.backend_state, key)
    {:reply, result, state}
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

  defp poll_unit_state(shell, unit, retries) do
    cmd = "systemctl show #{unit} --property=ActiveState"

    case Shell.execute(shell, cmd) do
      {:ok, output, _exit_code} ->
        case parse_unit_state(output) do
          "active" ->
            :ok

          "failed" ->
            {:error, {:unit_failed, unit}}

          _other when retries > 0 ->
            Process.sleep(1000)
            poll_unit_state(shell, unit, retries - 1)

          other ->
            {:error, {:unit_timeout, unit, other}}
        end

      {:error, reason} ->
        {:error, {:shell_error, reason}}
    end
  end

  defp parse_unit_state(output) do
    case Regex.run(~r/ActiveState=(\w+)/, output) do
      [_, state] -> state
      _ -> "unknown"
    end
  end

  defp poll_port_open(shell, port, retries) do
    cmd = "nc -z localhost #{port}"

    case Shell.execute(shell, cmd) do
      {:ok, _output, 0} ->
        :ok

      {:ok, _output, _nonzero} when retries > 0 ->
        Process.sleep(1000)
        poll_port_open(shell, port, retries - 1)

      {:ok, _output, _nonzero} ->
        {:error, {:port_not_open, port}}

      {:error, reason} ->
        {:error, {:shell_error, reason}}
    end
  end
end
