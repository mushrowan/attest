defmodule Attest.VLan do
  @moduledoc """
  Manages a VDE virtual ethernet switch for inter-VM networking

  Each VLan spawns a `vde_switch` process in hub mode, creating a unix
  socket that QEMU VMs can connect to for layer-2 networking.

  ## Example

      {:ok, vlan} = VLan.start_link(nr: 1, tmp_dir: "/tmp/test")
      socket_dir = VLan.socket_dir(vlan)
      # pass socket_dir to QEMU: -netdev vde,id=vlan1,sock=<socket_dir>
  """

  use GenServer

  require Logger

  defstruct [:nr, :socket_dir, :port]

  # client API

  @doc """
  Start a VLan process

  ## Options

  - `:nr` (required) — VLAN number
  - `:tmp_dir` (required) — base directory for VDE sockets
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get the VLAN number
  """
  @spec nr(GenServer.server()) :: non_neg_integer()
  def nr(vlan) do
    GenServer.call(vlan, :nr)
  end

  @doc """
  Get the VDE socket directory path
  """
  @spec socket_dir(GenServer.server()) :: String.t()
  def socket_dir(vlan) do
    GenServer.call(vlan, :socket_dir)
  end

  @doc """
  Generate a deterministic MAC address for a VM on a VLAN

  Format: 52:54:00:12:XX:YY where XX = VLAN number, YY = node number
  """
  @spec qemu_nic_mac(non_neg_integer(), non_neg_integer()) :: String.t()
  def qemu_nic_mac(vlan_nr, node_nr) do
    net = vlan_nr |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    machine = node_nr |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    "52:54:00:12:#{net}:#{machine}"
  end

  @doc """
  Generate QEMU NIC flags for connecting a VM to a VLAN

  Returns a list of two strings:
  - `-device virtio-net-pci,netdev=vlanN,mac=...`
  - `-netdev vde,id=vlanN,sock=...`
  """
  @spec qemu_nic_flags(non_neg_integer(), non_neg_integer(), String.t()) :: [String.t()]
  def qemu_nic_flags(vlan_nr, node_nr, socket_dir) do
    mac = qemu_nic_mac(vlan_nr, node_nr)
    id = "vlan#{vlan_nr}"

    [
      "-device virtio-net-pci,netdev=#{id},mac=#{mac}",
      "-netdev vde,id=#{id},sock=#{socket_dir}"
    ]
  end

  # server callbacks

  @impl true
  def init(opts) do
    nr = Keyword.fetch!(opts, :nr)
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    socket_dir = Path.join(tmp_dir, "vde#{nr}.ctl")

    Logger.info("starting VLan #{nr} with socket at #{socket_dir}")

    cmd =
      "vde_switch --sock #{socket_dir} --dirmode 0700 --hub"

    port =
      Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout])

    # wait for socket dir to appear
    wait_for_socket_dir(socket_dir, 5_000)

    # set env var for QEMU start scripts (matches Python driver)
    System.put_env("QEMU_VDE_SOCKET_#{nr}", socket_dir)

    state = %__MODULE__{
      nr: nr,
      socket_dir: socket_dir,
      port: port
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:nr, _from, state) do
    {:reply, state.nr, state}
  end

  @impl true
  def handle_call(:socket_dir, _from, state) do
    {:reply, state.socket_dir, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("vde_switch[#{state.nr}]: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("vde_switch[#{state.nr}] exited with code #{code}")
    {:noreply, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("stopping VLan #{state.nr}")

    if state.port do
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp wait_for_socket_dir(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_socket_dir(path, deadline)
  end

  defp do_wait_for_socket_dir(path, deadline) do
    if File.dir?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "VDE socket dir #{path} not created within timeout"
      else
        Process.sleep(50)
        do_wait_for_socket_dir(path, deadline)
      end
    end
  end
end
