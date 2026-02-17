defmodule Attest do
  @moduledoc """
  NixOS test driver rewritten in Elixir.

  This module provides the main API for running NixOS integration tests.
  It leverages OTP supervision trees for managing VM lifecycle and
  provides a clean DSL for writing tests.

  ## Example

      # start VMs and run test
      Attest.run_test(
        machines: ["web", "db"],
        test: fn driver ->
          driver
          |> Attest.start_all()
          |> Attest.machine("web")
          |> Attest.wait_for_unit("nginx.service")

          driver
          |> Attest.machine("db")
          |> Attest.succeed("systemctl is-active postgresql")
        end
      )
  """

  alias Attest.Driver
  alias Attest.Machine

  @doc """
  Start all machines in the test.
  """
  @spec start_all(GenServer.server()) :: GenServer.server()
  def start_all(driver) do
    Driver.start_all(driver)
    driver
  end

  @doc """
  Get a machine by name.
  """
  @spec machine(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def machine(driver, name) do
    Driver.get_machine(driver, name)
  end

  @doc """
  Wait for a systemd unit to become active.
  """
  @spec wait_for_unit(GenServer.server(), String.t(), keyword()) :: GenServer.server()
  def wait_for_unit(machine, unit, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    Machine.wait_for_unit(machine, unit, timeout)
    machine
  end

  @doc """
  Execute a command and expect it to succeed (exit code 0).
  """
  @spec succeed(GenServer.server(), String.t()) :: String.t()
  def succeed(machine, command) do
    Machine.succeed(machine, command)
  end

  @doc """
  Execute a command and expect it to fail (non-zero exit code).
  """
  @spec fail(GenServer.server(), String.t()) :: String.t()
  def fail(machine, command) do
    Machine.fail(machine, command)
  end

  @doc """
  Sleep for the given number of seconds
  """
  @spec sleep(GenServer.server(), number()) :: :ok
  def sleep(machine, secs) do
    Machine.sleep(machine, secs)
  end

  @doc """
  Execute a command and return {exit_code, output}.
  """
  @spec execute(GenServer.server(), String.t()) :: Attest.Machine.execute_result()
  def execute(machine, command) do
    Machine.execute(machine, command)
  end

  @doc """
  Take a screenshot of the VM display.
  """
  @spec screenshot(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def screenshot(machine, filename) do
    Machine.screenshot(machine, filename)
  end

  @doc """
  Extract text from the current screen via OCR.
  """
  @spec get_screen_text(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_screen_text(machine) do
    Machine.get_screen_text(machine)
  end

  @doc """
  Extract text from the current screen via OCR with preprocessing variants.
  """
  @spec get_screen_text_variants(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def get_screen_text_variants(machine) do
    Machine.get_screen_text_variants(machine)
  end

  @doc """
  Wait until screen text matches a regex.
  """
  @spec wait_for_text(GenServer.server(), Regex.t(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_text(machine, regex, opts \\ []) do
    Machine.wait_for_text(machine, regex, opts)
  end

  @doc """
  Wait for a port to be open.
  """
  @spec wait_for_open_port(GenServer.server(), non_neg_integer(), keyword()) ::
          GenServer.server()
  def wait_for_open_port(machine, port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    Machine.wait_for_open_port(machine, port, timeout)
    machine
  end

  @doc """
  Retry a command until it succeeds (exit code 0).
  """
  @spec wait_until_succeeds(GenServer.server(), String.t(), keyword()) :: String.t()
  def wait_until_succeeds(machine, command, opts \\ []) do
    Machine.wait_until_succeeds(machine, command, opts)
  end

  @doc """
  Retry a command until it fails (non-zero exit code).
  """
  @spec wait_until_fails(GenServer.server(), String.t(), keyword()) :: String.t()
  def wait_until_fails(machine, command, opts \\ []) do
    Machine.wait_until_fails(machine, command, opts)
  end

  @doc """
  Wait for a file to exist in the guest.
  """
  @spec wait_for_file(GenServer.server(), String.t(), keyword()) :: :ok
  def wait_for_file(machine, path, opts \\ []) do
    Machine.wait_for_file(machine, path, opts)
  end

  @doc """
  Run a systemctl command. Pass `user: "username"` for user units.
  """
  @spec systemctl(GenServer.server(), String.t(), keyword()) :: Machine.execute_result()
  def systemctl(machine, args, opts \\ []) do
    Machine.systemctl(machine, args, opts)
  end

  @doc """
  Force-crash the VM.
  """
  @spec crash(GenServer.server()) :: :ok | {:error, term()}
  def crash(machine) do
    Machine.crash(machine)
  end

  @doc """
  Get all properties of a systemd unit as a map.
  """
  @spec get_unit_info(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_unit_info(machine, unit) do
    Machine.get_unit_info(machine, unit)
  end

  @doc """
  Get a single systemd unit property.
  """
  @spec get_unit_property(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def get_unit_property(machine, unit, property) do
    Machine.get_unit_property(machine, unit, property)
  end

  @doc """
  Assert a unit is in the expected state.
  """
  @spec require_unit_state(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def require_unit_state(machine, unit, expected_state \\ "active") do
    Machine.require_unit_state(machine, unit, expected_state)
  end

  @doc """
  Copy a file from host to guest via base64 shell transfer.
  """
  @spec copy_from_host_via_shell(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def copy_from_host_via_shell(machine, source, target) do
    Machine.copy_from_host_via_shell(machine, source, target)
  end

  @doc """
  Send a key combination to the VM (e.g. "ctrl-alt-delete", "ret").
  """
  @spec send_key(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_key(machine, key) do
    Machine.send_key(machine, key)
  end

  @doc """
  Type a string of characters on the virtual keyboard.
  """
  @spec send_chars(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_chars(machine, chars, opts \\ []) do
    Machine.send_chars(machine, chars, opts)
  end

  @doc """
  Disable the inter-VM network link (simulates cable unplug).
  """
  @spec block(GenServer.server()) :: :ok | {:error, term()}
  def block(machine) do
    Machine.block(machine)
  end

  @doc """
  Re-enable the inter-VM network link (simulates cable plug).
  """
  @spec unblock(GenServer.server()) :: :ok | {:error, term()}
  def unblock(machine) do
    Machine.unblock(machine)
  end

  @doc """
  Add a TCP port forward from host to guest.
  """
  @spec forward_port(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def forward_port(machine, host_port, guest_port) do
    Machine.forward_port(machine, host_port, guest_port)
  end

  @doc """
  Reboot the VM by sending ctrl-alt-delete and wait for shell reconnect.
  """
  @spec reboot(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def reboot(machine, timeout \\ 120_000) do
    Machine.reboot(machine, timeout)
  end

  @doc """
  Read the text content of a virtual terminal.
  """
  @spec get_tty_text(GenServer.server(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def get_tty_text(machine, tty \\ 1) do
    Machine.get_tty_text(machine, tty)
  end

  @doc """
  Poll a virtual terminal until its content matches a regex.
  """
  @spec wait_until_tty_matches(GenServer.server(), pos_integer(), Regex.t(), keyword()) ::
          {:ok, String.t()} | {:error, :timeout}
  def wait_until_tty_matches(machine, tty, regex, opts \\ []) do
    Machine.wait_until_tty_matches(machine, tty, regex, opts)
  end

  @doc """
  Wait for a TCP port to be closed.
  """
  @spec wait_for_closed_port(GenServer.server(), non_neg_integer(), keyword()) :: :ok
  def wait_for_closed_port(machine, port, opts \\ []) do
    Machine.wait_for_closed_port(machine, port, opts)
  end

  @doc """
  Wait for a unix domain socket to exist.
  """
  @spec wait_for_open_unix_socket(GenServer.server(), String.t(), keyword()) :: :ok
  def wait_for_open_unix_socket(machine, path, opts \\ []) do
    Machine.wait_for_open_unix_socket(machine, path, opts)
  end

  @doc """
  Start a systemd unit. Pass `user: "username"` for user units.
  """
  @spec start_job(GenServer.server(), String.t(), keyword()) :: Machine.execute_result()
  def start_job(machine, unit, opts \\ []) do
    Machine.start_job(machine, unit, opts)
  end

  @doc """
  Stop a systemd unit. Pass `user: "username"` for user units.
  """
  @spec stop_job(GenServer.server(), String.t(), keyword()) :: Machine.execute_result()
  def stop_job(machine, unit, opts \\ []) do
    Machine.stop_job(machine, unit, opts)
  end

  @doc """
  Copy a file from guest to host via the shell backdoor.
  """
  @spec copy_from_vm(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def copy_from_vm(machine, source, dest) do
    Machine.copy_from_vm(machine, source, dest)
  end

  @doc """
  Create a VM snapshot (firecracker only)
  """
  @spec snapshot_create(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def snapshot_create(machine, snapshot_dir) do
    Machine.snapshot_create(machine, snapshot_dir)
  end

  @doc """
  Restore a VM from a snapshot (firecracker only)
  """
  @spec snapshot_restore(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def snapshot_restore(machine, snapshot_dir) do
    Machine.snapshot_restore(machine, snapshot_dir)
  end

  @doc """
  Send raw characters to the kernel serial console.
  """
  @spec send_console(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_console(machine, chars) do
    Machine.send_console(machine, chars)
  end

  @doc """
  Get accumulated console/serial output from the VM.
  """
  @spec get_console_log(GenServer.server()) :: String.t()
  def get_console_log(machine) do
    Machine.get_console_log(machine)
  end

  @doc """
  Wait until the console output matches a regex.
  """
  @spec wait_for_console_text(GenServer.server(), Regex.t(), keyword()) ::
          :ok | {:error, :timeout}
  def wait_for_console_text(machine, regex, opts \\ []) do
    Machine.wait_for_console_text(machine, regex, opts)
  end
end
