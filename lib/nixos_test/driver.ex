defmodule NixosTest.Driver do
  @moduledoc """
  Main test driver that coordinates VMs and test execution.

  The Driver is responsible for:
  - Loading test configuration
  - Starting/stopping machines via MachineSupervisor
  - Managing VLANs
  - Executing the test script
  - Handling global timeout
  """
  use GenServer

  require Logger

  defstruct [
    :machines,
    :vlans,
    :test_script,
    :out_dir,
    :global_timeout,
    :timeout_ref
  ]

  # client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start all machines in parallel.
  """
  def start_all(driver) do
    GenServer.call(driver, :start_all, :infinity)
  end

  @doc """
  Get a machine by name.
  """
  def get_machine(driver, name) do
    GenServer.call(driver, {:get_machine, name})
  end

  @doc """
  Run the test script.
  """
  def run_tests(driver) do
    GenServer.call(driver, :run_tests, :infinity)
  end

  # server callbacks

  @impl true
  def init(opts) do
    machine_configs = Keyword.get(opts, :machines, [])
    machines = start_machines(machine_configs)

    state = %__MODULE__{
      machines: machines,
      vlans: %{},
      test_script: Keyword.get(opts, :test_script),
      out_dir: Keyword.get(opts, :out_dir, System.tmp_dir!()),
      global_timeout: Keyword.get(opts, :global_timeout, 3600_000)
    }

    # start global timeout timer
    timeout_ref = Process.send_after(self(), :global_timeout, state.global_timeout)

    {:ok, %{state | timeout_ref: timeout_ref}}
  end

  defp start_machines(configs) do
    configs
    |> Enum.map(fn config ->
      name = Map.fetch!(config, :name)
      opts = Map.to_list(config)

      {:ok, pid} =
        DynamicSupervisor.start_child(NixosTest.MachineSupervisor, {NixosTest.Machine, opts})

      {name, pid}
    end)
    |> Map.new()
  end

  @impl true
  def handle_call(:start_all, _from, state) do
    Logger.info("starting all machines")

    # start all machines in parallel (5 min timeout for VM boot)
    state.machines
    |> Task.async_stream(
      fn {_name, pid} -> NixosTest.Machine.start(pid) end,
      timeout: 300_000
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_machine, name}, _from, state) do
    case Map.get(state.machines, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        {:reply, {:ok, pid}, state}
    end
  end

  @impl true
  def handle_call(:run_tests, _from, state) do
    Logger.info("running test script")

    # TODO: execute test script
    result = :ok

    {:reply, result, state}
  end

  @impl true
  def handle_info(:global_timeout, state) do
    Logger.error("global timeout reached, terminating test")
    {:stop, :global_timeout, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("driver terminating: #{inspect(reason)}")

    # cancel timeout if still pending
    if state.timeout_ref do
      Process.cancel_timer(state.timeout_ref)
    end

    # cleanup machines (some may already be stopped)
    for {_name, pid} <- state.machines do
      if Process.alive?(pid) do
        GenServer.stop(pid, :shutdown)
      end
    end

    :ok
  end
end
