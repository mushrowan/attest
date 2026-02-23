defmodule Attest.Machine do
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

  alias Attest.Machine.{Keyboard, OCR, Shell}

  defstruct [
    :name,
    :shell,
    :backend_mod,
    :backend_state,
    booted: false,
    connected: false,
    callbacks: [],
    console_log: ""
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

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Attest.MachineRegistry, name}})
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
  Retry a command until it succeeds (exit code 0)

  Returns the command output on success, raises on timeout.
  """
  @spec wait_until_succeeds(GenServer.server(), String.t(), keyword()) :: String.t()
  def wait_until_succeeds(machine, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    interval = Keyword.get(opts, :interval, 1000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_retry_until(machine, command, :succeed, interval, deadline)
  end

  @doc """
  Retry a command until it fails (non-zero exit code)

  Returns the command output on failure, raises on timeout.
  """
  @spec wait_until_fails(GenServer.server(), String.t(), keyword()) :: String.t()
  def wait_until_fails(machine, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    interval = Keyword.get(opts, :interval, 1000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_retry_until(machine, command, :fail, interval, deadline)
  end

  defp do_retry_until(machine, command, mode, interval, deadline) do
    result = execute(machine, command)

    if retry_done?(result, mode) do
      extract_output(result)
    else
      retry_or_raise(machine, command, mode, interval, deadline, result)
    end
  end

  defp retry_done?({0, _output}, :succeed), do: true
  defp retry_done?({code, _output}, :fail) when is_integer(code) and code != 0, do: true
  defp retry_done?(_result, _mode), do: false

  defp extract_output({_code, output}) when is_binary(output), do: output

  defp retry_or_raise(machine, command, mode, interval, deadline, last_result) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise retry_timeout_message(mode, last_result)
    else
      Process.sleep(interval)
      do_retry_until(machine, command, mode, interval, deadline)
    end
  end

  defp retry_timeout_message(mode, last_result) do
    {code, output} =
      case last_result do
        {c, o} when is_integer(c) -> {c, o}
        {:error, reason} -> {-1, inspect(reason)}
      end

    verb = if mode == :succeed, do: "succeed", else: "fail"
    "command did not #{verb} within timeout (last exit: #{code}, output: #{output})"
  end

  @doc """
  Wait for a file to exist in the guest
  """
  @spec wait_for_file(GenServer.server(), String.t(), keyword()) :: :ok
  def wait_for_file(machine, path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    wait_until_succeeds(machine, "test -e #{path}", timeout: timeout)
    :ok
  end

  @doc """
  Run a systemctl command and return {exit_code, output}

  Pass `user: "username"` to run as a user systemd instance.
  """
  @spec systemctl(GenServer.server(), String.t(), keyword()) :: execute_result()
  def systemctl(machine, args, opts \\ []) do
    case Keyword.get(opts, :user) do
      nil ->
        execute(machine, "systemctl #{args}")

      user ->
        escaped = String.replace(args, "'", "\\'")

        execute(
          machine,
          "su -l #{user} --shell /bin/sh -c " <>
            "'XDG_RUNTIME_DIR=/run/user/`id -u #{user}` " <>
            "systemctl --user #{escaped}'"
        )
    end
  end

  @doc """
  Sleep for the given number of seconds
  """
  @spec sleep(GenServer.server(), number()) :: :ok
  def sleep(_machine, secs) do
    ms = round(secs * 1000)
    Logger.info("sleeping for #{secs}s")
    Process.sleep(ms)
    :ok
  end

  @doc """
  Force-crash the VM (immediate quit, no graceful shutdown)
  """
  @spec crash(GenServer.server()) :: :ok | {:error, term()}
  def crash(machine) do
    halt(machine, 5000)
  end

  @doc """
  Read the text content of a virtual terminal
  """
  @spec get_tty_text(GenServer.server(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def get_tty_text(machine, tty \\ 1) do
    case execute(machine, "cat /dev/vcs#{tty}") do
      {0, output} -> {:ok, output}
      {code, output} when is_integer(code) -> {:error, {:exit, code, output}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Poll a virtual terminal until its content matches a regex

  Returns the matching text on success.
  """
  @spec wait_until_tty_matches(GenServer.server(), pos_integer(), Regex.t(), keyword()) ::
          {:ok, String.t()} | {:error, :timeout}
  def wait_until_tty_matches(machine, tty, regex, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    interval = Keyword.get(opts, :interval, 500)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_tty_text(machine, tty, regex, interval, deadline)
  end

  defp poll_tty_text(machine, tty, regex, interval, deadline) do
    case get_tty_text(machine, tty) do
      {:ok, text} ->
        if Regex.match?(regex, text) do
          {:ok, text}
        else
          retry_tty_poll(machine, tty, regex, interval, deadline)
        end

      {:error, _} ->
        retry_tty_poll(machine, tty, regex, interval, deadline)
    end
  end

  defp retry_tty_poll(machine, tty, regex, interval, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      Process.sleep(interval)
      poll_tty_text(machine, tty, regex, interval, deadline)
    end
  end

  @doc """
  Wait for a TCP port to be closed
  """
  @spec wait_for_closed_port(GenServer.server(), non_neg_integer(), keyword()) :: :ok
  def wait_for_closed_port(machine, port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    wait_until_fails(machine, "nc -z localhost #{port}", timeout: timeout)
    :ok
  end

  @doc """
  Wait for a unix domain socket to exist
  """
  @spec wait_for_open_unix_socket(GenServer.server(), String.t(), keyword()) :: :ok
  def wait_for_open_unix_socket(machine, path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    wait_until_succeeds(machine, "test -S #{path}", timeout: timeout)
    :ok
  end

  @doc """
  Start a systemd unit

  Pass `user: "username"` to start a user unit.
  """
  @spec start_job(GenServer.server(), String.t(), keyword()) :: execute_result()
  def start_job(machine, unit, opts \\ []) do
    systemctl(machine, "start #{unit}", opts)
  end

  @doc """
  Stop a systemd unit

  Pass `user: "username"` to stop a user unit.
  """
  @spec stop_job(GenServer.server(), String.t(), keyword()) :: execute_result()
  def stop_job(machine, unit, opts \\ []) do
    systemctl(machine, "stop #{unit}", opts)
  end

  @doc """
  Copy a file from guest to host via the shell backdoor (base64 encoded)
  """
  @spec copy_from_vm(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def copy_from_vm(machine, source, dest) do
    case execute(machine, "base64 -w 0 #{source}") do
      {0, encoded} ->
        case Base.decode64(encoded) do
          {:ok, content} ->
            File.mkdir_p!(Path.dirname(dest))
            File.write!(dest, content)
            :ok

          :error ->
            {:error, :decode_failed}
        end

      {code, output} when is_integer(code) ->
        {:error, {:exit, code, output}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Get all properties of a systemd unit as a map
  """
  @spec get_unit_info(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_unit_info(machine, unit) do
    case execute(machine, "systemctl --no-pager show #{unit}") do
      {0, output} -> {:ok, parse_unit_info(output)}
      {code, output} when is_integer(code) -> {:error, {:exit, code, output}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Get a single systemd unit property
  """
  @spec get_unit_property(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def get_unit_property(machine, unit, property) do
    case execute(machine, "systemctl --no-pager show #{unit} --property=#{property}") do
      {0, output} ->
        info = parse_unit_info(output)

        case Map.fetch(info, property) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:property_not_found, property}}
        end

      {code, output} when is_integer(code) ->
        {:error, {:exit, code, output}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Assert a unit is in the expected state, returns :ok or {:error, reason}
  """
  @spec require_unit_state(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def require_unit_state(machine, unit, expected_state \\ "active") do
    case get_unit_property(machine, unit, "ActiveState") do
      {:ok, ^expected_state} -> :ok
      {:ok, actual} -> {:error, {:unexpected_state, unit, expected_state, actual}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Copy a file from host to guest via the shell backdoor (base64 encoded)
  """
  @spec copy_from_host_via_shell(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def copy_from_host_via_shell(machine, source, target) do
    content = File.read!(source)
    encoded = Base.encode64(content)

    succeed(machine, "mkdir -p $(dirname #{target})")
    succeed(machine, "echo -n #{encoded} | base64 -d > #{target}")
    :ok
  end

  @doc """
  Parse systemctl show output into a key-value map
  """
  @spec parse_unit_info(String.t()) :: map()
  def parse_unit_info(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, &parse_unit_line/2)
  end

  defp parse_unit_line(line, acc) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        if key != "", do: Map.put(acc, key, String.trim(value)), else: acc

      _ ->
        acc
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
  Get the accumulated console/serial output
  """
  @spec get_console_log(GenServer.server()) :: String.t()
  def get_console_log(machine) do
    GenServer.call(machine, :get_console_log)
  end

  @doc """
  Wait until the console output matches a regex

  Polls the console log buffer at 200ms intervals.
  """
  @spec wait_for_console_text(GenServer.server(), Regex.t(), keyword()) ::
          :ok | {:error, :timeout}
  def wait_for_console_text(machine, regex, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_console_text(machine, regex, deadline)
  end

  defp poll_console_text(machine, regex, deadline) do
    log = get_console_log(machine)

    if Regex.match?(regex, log) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(200)
        poll_console_text(machine, regex, deadline)
      end
    end
  end

  @doc """
  Disable the inter-VM network link (simulates cable unplug)
  """
  @spec block(GenServer.server()) :: :ok | {:error, term()}
  def block(machine) do
    GenServer.call(machine, :block)
  end

  @doc """
  Re-enable the inter-VM network link (simulates cable plug)
  """
  @spec unblock(GenServer.server()) :: :ok | {:error, term()}
  def unblock(machine) do
    GenServer.call(machine, :unblock)
  end

  @doc """
  Add a TCP port forward from host to guest via QEMU SLIRP networking
  """
  @spec forward_port(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def forward_port(machine, host_port, guest_port) do
    GenServer.call(machine, {:forward_port, host_port, guest_port})
  end

  @doc """
  Reboot the VM by sending ctrl-alt-delete

  Sends ctrl-alt-delete, then waits for the shell to reconnect.
  The VM must have been started without -no-reboot for this to work.
  """
  @spec reboot(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def reboot(machine, timeout \\ 120_000) do
    GenServer.call(machine, {:reboot, timeout}, timeout + 30_000)
  end

  @doc """
  Send raw characters to the kernel serial console

  Writes directly to QEMU's stdin, allowing interaction with the
  systemd emergency mode or boot console.
  """
  @spec send_console(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_console(machine, chars) do
    GenServer.call(machine, {:send_console, chars})
  end

  @doc """
  Create a VM snapshot (firecracker only)

  Pauses the VM and writes snapshot + memory state to `snapshot_dir`.
  """
  @spec snapshot_create(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def snapshot_create(machine, snapshot_dir) do
    GenServer.call(machine, {:snapshot_create, snapshot_dir}, :infinity)
  end

  @doc """
  Restore a VM from a snapshot (firecracker only)

  Loads snapshot + memory state from `snapshot_dir` and resumes.
  """
  @spec snapshot_restore(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def snapshot_restore(machine, snapshot_dir) do
    GenServer.call(machine, {:snapshot_restore, snapshot_dir}, :infinity)
  end

  @doc """
  Get the host-side state directory for this machine
  """
  @spec state_dir(GenServer.server()) :: String.t()
  def state_dir(machine) do
    GenServer.call(machine, :state_dir)
  end

  @doc """
  Take a screenshot
  """
  @spec screenshot(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def screenshot(machine, filename) do
    GenServer.call(machine, {:screenshot, filename})
  end

  @doc """
  Extract text from the current screen via OCR

  Takes a screenshot, runs tesseract, returns the extracted text.
  Requires tesseract to be available on PATH.
  """
  @spec get_screen_text(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_screen_text(machine) do
    GenServer.call(machine, :get_screen_text, 60_000)
  end

  @doc """
  Extract text from the current screen via OCR with preprocessing variants

  Takes a screenshot, runs tesseract on raw + preprocessed variants.
  Returns a list of three text strings for better detection coverage.
  Requires tesseract and imagemagick to be available on PATH.
  """
  @spec get_screen_text_variants(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def get_screen_text_variants(machine) do
    GenServer.call(machine, :get_screen_text_variants, 60_000)
  end

  @doc """
  Wait until screen text matches a regex

  Polls `get_screen_text_variants/1` until any variant matches.

  ## Options

  - `:timeout` — max wait time in ms (default: 900_000)
  """
  @spec wait_for_text(GenServer.server(), Regex.t(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_text(machine, regex, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_text(machine, regex, deadline)
  end

  defp do_wait_for_text(machine, regex, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case get_screen_text_variants(machine) do
        {:ok, variants} ->
          if Enum.any?(variants, &Regex.match?(regex, &1)) do
            :ok
          else
            Process.sleep(1_000)
            do_wait_for_text(machine, regex, deadline)
          end

        {:error, _reason} ->
          Process.sleep(1_000)
          do_wait_for_text(machine, regex, deadline)
      end
    end
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
    case send_key(machine, Keyboard.char_to_key(char)) do
      :ok ->
        if delay > 0, do: Process.sleep(delay)
        {:cont, :ok}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  @doc """
  Map a single character to a QMP key name

  Delegates to `Attest.Machine.Keyboard.char_to_key/1`.
  """
  @spec char_to_key(String.t()) :: String.t()
  defdelegate char_to_key(char), to: Keyboard

  # server callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    backend_mod = Keyword.get(opts, :backend, Attest.Machine.Backend.QEMU)

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
  def handle_call(:get_screen_text, _from, state) do
    result = do_ocr(state, &OCR.perform_ocr/1)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_screen_text_variants, _from, state) do
    result = do_ocr(state, &OCR.perform_ocr_variants/1)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:send_key, key}, _from, state) do
    Logger.info("sending key #{key} to #{state.name}")
    result = state.backend_mod.send_key(state.backend_state, key)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:send_console, chars}, _from, state) do
    Logger.info("sending console chars to #{state.name}")
    result = state.backend_mod.send_console(state.backend_state, chars)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:block, _from, state) do
    Logger.info("blocking network on #{state.name}")
    result = state.backend_mod.block(state.backend_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:unblock, _from, state) do
    Logger.info("unblocking network on #{state.name}")
    result = state.backend_mod.unblock(state.backend_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:forward_port, host_port, guest_port}, _from, state) do
    Logger.info("forwarding port #{host_port} -> #{guest_port} on #{state.name}")
    result = state.backend_mod.forward_port(state.backend_state, host_port, guest_port)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:reboot, timeout}, _from, state) do
    Logger.info("rebooting #{state.name}")

    with :ok <- state.backend_mod.send_key(state.backend_state, "ctrl-alt-delete") do
      state = %{state | connected: false}

      if state.shell do
        Logger.info("waiting for shell reconnect on #{state.name}")

        case Shell.reconnect(state.shell, timeout) do
          :ok ->
            Logger.info("shell reconnected on #{state.name}")
            {:reply, :ok, %{state | connected: true}}

          {:error, reason} ->
            Logger.warning("shell reconnect failed on #{state.name}: #{inspect(reason)}")
            {:reply, {:error, {:reconnect_failed, reason}}, state}
        end
      else
        {:reply, :ok, state}
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:state_dir, _from, state) do
    {:reply, state.backend_state.state_dir, state}
  end

  @impl true
  def handle_call({:snapshot_create, snapshot_dir}, _from, state) do
    Logger.info("creating snapshot for #{state.name} in #{snapshot_dir}")
    result = state.backend_mod.snapshot_create(state.backend_state, snapshot_dir)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:snapshot_restore, snapshot_dir}, _from, state) do
    Logger.info("restoring snapshot for #{state.name} from #{snapshot_dir}")

    case state.backend_mod.restore_from_snapshot(state.backend_state, snapshot_dir) do
      {:ok, shell_pid, backend_state} ->
        state = %{
          state
          | backend_state: backend_state,
            shell: shell_pid,
            booted: true,
            connected: shell_pid != nil
        }

        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:get_console_log, _from, state) do
    {:reply, state.console_log, state}
  end

  # port stdout/stderr data from QEMU backend (port owner is Machine process)
  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    text = to_string(data)
    truncated = String.slice(text, 0, 200)
    Logger.info("QEMU[#{state.name}]: #{truncated}")
    {:noreply, %{state | console_log: state.console_log <> text}}
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

  # take a temporary screenshot and run an OCR function on it
  defp do_ocr(state, ocr_fn) do
    tmp = Path.join(System.tmp_dir!(), "ocr-#{state.name}-#{:rand.uniform(100_000)}.ppm")

    case state.backend_mod.screenshot(state.backend_state, tmp) do
      :ok ->
        result = ocr_fn.(tmp)
        File.rm(tmp)
        result

      {:error, :unsupported} ->
        {:error, :unsupported}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
