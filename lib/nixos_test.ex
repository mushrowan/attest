defmodule NixosTest do
  @moduledoc """
  NixOS test driver rewritten in Elixir.

  This module provides the main API for running NixOS integration tests.
  It leverages OTP supervision trees for managing VM lifecycle and
  provides a clean DSL for writing tests.

  ## Example

      # start VMs and run test
      NixosTest.run_test(
        machines: ["web", "db"],
        test: fn driver ->
          driver
          |> NixosTest.start_all()
          |> NixosTest.machine("web")
          |> NixosTest.wait_for_unit("nginx.service")

          driver
          |> NixosTest.machine("db")
          |> NixosTest.succeed("systemctl is-active postgresql")
        end
      )
  """

  alias NixosTest.Driver
  alias NixosTest.Machine

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
  Execute a command and return {exit_code, output}.
  """
  @spec execute(GenServer.server(), String.t()) :: NixosTest.Machine.execute_result()
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
  Wait for a port to be open.
  """
  @spec wait_for_open_port(GenServer.server(), non_neg_integer(), keyword()) ::
          GenServer.server()
  def wait_for_open_port(machine, port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 900_000)
    Machine.wait_for_open_port(machine, port, timeout)
    machine
  end
end
