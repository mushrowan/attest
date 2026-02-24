defmodule Attest.Driver do
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

  alias Attest.VLan

  defstruct [
    :machines,
    :vlans,
    :vlan_pids,
    :test_script,
    :out_dir,
    :tmp_dir,
    :global_timeout,
    :timeout_ref
  ]

  # client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start all machines in parallel.
  """
  @spec start_all(GenServer.server()) :: :ok
  def start_all(driver) do
    GenServer.call(driver, :start_all, :infinity)
  end

  @doc """
  Get a machine by name.
  """
  @spec get_machine(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_machine(driver, name) do
    GenServer.call(driver, {:get_machine, name})
  end

  @doc """
  Get all VLANs as a list of {nr, socket_dir} tuples
  """
  @spec get_vlans(GenServer.server()) :: [{non_neg_integer(), String.t()}]
  def get_vlans(driver) do
    GenServer.call(driver, :get_vlans)
  end

  @doc """
  Run the test script.
  """
  @spec run_tests(GenServer.server()) :: :ok
  def run_tests(driver) do
    GenServer.call(driver, :run_tests, :infinity)
  end

  # server callbacks

  @impl true
  def init(opts) do
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    vlan_nrs = opts |> Keyword.get(:vlans, []) |> Enum.uniq()
    vlan_pids = start_vlans(vlan_nrs, tmp_dir)

    machine_configs = Keyword.get(opts, :machines, [])
    machines = start_machines(machine_configs)

    state = %__MODULE__{
      machines: machines,
      vlans: vlan_nrs,
      vlan_pids: vlan_pids,
      tmp_dir: tmp_dir,
      test_script: Keyword.get(opts, :test_script),
      out_dir: Keyword.get(opts, :out_dir, tmp_dir),
      global_timeout: Keyword.get(opts, :global_timeout, 3_600_000)
    }

    # start global timeout timer
    timeout_ref = Process.send_after(self(), :global_timeout, state.global_timeout)

    {:ok, %{state | timeout_ref: timeout_ref}}
  end

  defp start_vlans(vlan_nrs, tmp_dir) do
    Enum.map(vlan_nrs, fn nr ->
      Logger.info("starting VLan #{nr}")
      {:ok, pid} = VLan.start_link(nr: nr, tmp_dir: tmp_dir)
      {nr, pid}
    end)
  end

  defp start_machines(configs) do
    configs
    |> Enum.map(fn config ->
      name = Map.fetch!(config, :name)
      opts = Map.to_list(config)

      {:ok, pid} =
        DynamicSupervisor.start_child(Attest.MachineSupervisor, {Attest.Machine, opts})

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
      fn {_name, pid} -> Attest.Machine.start(pid) end,
      timeout: 300_000
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_vlans, _from, state) do
    vlans =
      Enum.map(state.vlan_pids, fn {nr, pid} ->
        {nr, VLan.socket_dir(pid)}
      end)

    {:reply, vlans, state}
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

    # shut down all machines in parallel, then wait for full cleanup
    machines = for {name, pid} <- state.machines || %{}, Process.alive?(pid), do: {name, pid}

    refs =
      Enum.map(machines, fn {name, pid} ->
        ref = Process.monitor(pid)
        # spawn shutdown so all happen concurrently
        Task.start(fn -> safe_shutdown(name, pid) end)
        {ref, pid}
      end)

    # wait for all machines to fully terminate (deregister from Registry)
    for {ref, _pid} <- refs do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        30_000 -> :ok
      end
    end

    # cleanup VLANs
    for {_nr, pid} <- state.vlan_pids || [] do
      safe_stop(pid)
    end

    Logger.info("all machines shut down")
    :ok
  end

  defp safe_shutdown(name, pid) do
    try do
      if Attest.Machine.booted?(pid) do
        Attest.Machine.shutdown(pid, 30_000)
      end
    catch
      :exit, _ -> :ok
    end

    try do
      DynamicSupervisor.terminate_child(Attest.MachineSupervisor, pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end
end
