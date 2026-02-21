defmodule Attest.Machine.Backend.Firecracker do
  @moduledoc """
  Firecracker backend

  Manages firecracker microVM lifecycle: process spawning, REST API
  configuration, vsock shell connection. No VGA, QMP, or SLIRP —
  all VM interaction is via shell over vsock.

  ## Capabilities

  Firecracker does not support screenshots, keyboard simulation,
  SLIRP port forwarding, or serial console input. Network block/unblock
  is available via host-side `ip link` when TAP interfaces are configured.

  ## Config

  Required keys:
  - `:name` — machine name
  - `:firecracker_bin` — path to firecracker binary
  - `:kernel_image_path` — path to uncompressed vmlinux
  - `:rootfs_path` — path to ext4 root filesystem image
  - `:state_dir` — working directory for sockets and logs

  Optional keys:
  - `:initrd_path` — path to initrd (default: nil)
  - `:kernel_boot_args` — kernel command line (default: "console=ttyS0 reboot=k panic=1")
  - `:vcpu_count` — number of vCPUs (default: 1)
  - `:mem_size_mib` — memory in MiB (default: 256)
  - `:vsock_cid` — guest CID for vsock (default: 3)
  - `:vsock_port` — guest port for shell backdoor (default: 1234)
  - `:tap_interfaces` — list of {iface_id, host_dev_name, guest_mac} (default: [])
  - `:extra_drives` — list of {drive_id, path, is_read_only} (default: [])
  - `:log_level` — firecracker log level (default: "Warning")
  - `:huge_pages` — huge page size, "2M" or nil (default: nil)
  - `:entropy` — enable virtio-rng entropy device (default: false)
  """

  @behaviour Attest.Machine.Backend

  require Logger

  alias Attest.Machine.Backend.Firecracker.API
  alias Attest.Machine.Shell
  alias Attest.Machine.Shell.Transport.Vsock

  defstruct [
    :name,
    :firecracker_bin,
    :kernel_image_path,
    :rootfs_path,
    :initrd_path,
    :kernel_boot_args,
    :vcpu_count,
    :mem_size_mib,
    :vsock_cid,
    :vsock_port,
    :state_dir,
    :tap_interfaces,
    :extra_drives,
    :log_level,
    :huge_pages,
    :entropy,
    :api_socket_path,
    :vsock_uds_path,
    :log_path,
    :fc_port,
    :shell,
    port_exited: false
  ]

  @default_boot_args "console=ttyS0 reboot=k panic=1 i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd"

  # lifecycle

  @impl true
  def init(config) do
    state_dir = Map.get(config, :state_dir, "/tmp/fc-#{Map.get(config, :name, "unknown")}")

    {:ok,
     %__MODULE__{
       name: Map.get(config, :name, "unknown"),
       firecracker_bin: Map.get(config, :firecracker_bin),
       kernel_image_path: Map.get(config, :kernel_image_path),
       rootfs_path: Map.get(config, :rootfs_path),
       initrd_path: Map.get(config, :initrd_path),
       kernel_boot_args: Map.get(config, :kernel_boot_args, @default_boot_args),
       vcpu_count: Map.get(config, :vcpu_count, 1),
       mem_size_mib: Map.get(config, :mem_size_mib, 256),
       vsock_cid: Map.get(config, :vsock_cid, 3),
       vsock_port: Map.get(config, :vsock_port, 1234),
       state_dir: state_dir,
       tap_interfaces: Map.get(config, :tap_interfaces, []),
       extra_drives: Map.get(config, :extra_drives, []),
       log_level: Map.get(config, :log_level, "Warning"),
       huge_pages: Map.get(config, :huge_pages),
       entropy: Map.get(config, :entropy, false),
       api_socket_path: Path.join(state_dir, "firecracker.sock"),
       vsock_uds_path: Path.join(state_dir, "v.sock"),
       log_path: Path.join(state_dir, "firecracker.log")
     }}
  end

  @impl true
  def start(state) do
    File.mkdir_p!(state.state_dir)
    File.rm(state.api_socket_path)
    File.rm(state.vsock_uds_path)

    # spawn firecracker process
    Logger.info("spawning firecracker for #{state.name}")

    cmd = "#{state.firecracker_bin} --api-sock #{state.api_socket_path}"

    port =
      Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout])

    state = %{state | fc_port: port}

    # wait for API socket
    :ok = wait_for_file(state.api_socket_path, 10_000)

    # configure VM via REST API
    :ok = configure_vm(state)

    # boot
    Logger.info("booting firecracker VM #{state.name}")
    :ok = API.put(state.api_socket_path, "/actions", %{"action_type" => "InstanceStart"})

    # wait for vsock UDS
    :ok = wait_for_file(state.vsock_uds_path, 30_000)

    # connect shell via vsock
    Logger.info("connecting shell via vsock for #{state.name}")

    {:ok, shell} =
      Shell.start_link(
        socket_path: state.vsock_uds_path,
        transport: Vsock,
        transport_config: %{uds_path: state.vsock_uds_path, port: state.vsock_port}
      )

    :ok = Shell.wait_for_connection(shell, 120_000)
    state = %{state | shell: shell}

    {:ok, shell, state}
  end

  @impl true
  def shutdown(%{shell: nil} = state, timeout) do
    Logger.warning("shutdown on #{state.name}: no shell, using halt")
    halt(state, timeout)
  end

  def shutdown(%{shell: shell} = state, timeout) do
    Logger.info("shutting down #{state.name}")

    # reboot -f -p: force immediate power-off (no init, no ACPI needed)
    case Shell.execute(shell, "reboot -f -p") do
      {:ok, _, _} -> :ok
      {:error, :closed} -> :ok
      {:error, _reason} -> :ok
    end

    result = wait_for_process_exit(state, timeout)
    cleanup(state)
    result
  end

  @impl true
  def halt(state, timeout) do
    Logger.info("halting #{state.name}")

    # try SendCtrlAltDel first, then force-kill
    if File.exists?(state.api_socket_path) do
      API.put(state.api_socket_path, "/actions", %{"action_type" => "SendCtrlAltDel"})
    end

    case wait_for_process_exit(state, div(timeout, 2)) do
      :ok ->
        cleanup(state)
        :ok

      {:error, :timeout} ->
        # force kill via port close
        if state.fc_port do
          try do
            Port.close(state.fc_port)
          rescue
            ArgumentError -> :ok
          end
        end

        cleanup(state)
        :ok
    end
  end

  @impl true
  def wait_for_shutdown(state, timeout) do
    wait_for_process_exit(state, timeout)
  end

  @impl true
  def cleanup(state) do
    if state.shell && Process.alive?(state.shell) do
      GenServer.stop(state.shell, :normal)
    end

    if state.fc_port do
      try do
        Port.close(state.fc_port)
      rescue
        ArgumentError -> :ok
      end
    end

    File.rm(state.api_socket_path)
    File.rm(state.vsock_uds_path)

    :ok
  end

  # unsupported capabilities — no VGA, QMP, or SLIRP

  @impl true
  def screenshot(_state, _filename), do: {:error, :unsupported}

  @impl true
  def send_key(_state, _key), do: {:error, :unsupported}

  @impl true
  def forward_port(_state, _host_port, _guest_port), do: {:error, :unsupported}

  @impl true
  def send_console(_state, _chars), do: {:error, :unsupported}

  # snapshots

  @impl true
  def snapshot_create(state, snapshot_dir) do
    api = state.api_socket_path
    File.mkdir_p!(snapshot_dir)
    snapshot_path = Path.join(snapshot_dir, "snapshot_file")
    mem_path = Path.join(snapshot_dir, "mem_file")

    with :ok <- API.patch(api, "/vm", %{"state" => "Paused"}),
         :ok <-
           API.put(api, "/snapshot/create", %{
             "snapshot_path" => snapshot_path,
             "mem_file_path" => mem_path
           }) do
      :ok
    end
  end

  @impl true
  def snapshot_load(state, snapshot_dir) do
    api = state.api_socket_path
    snapshot_path = Path.join(snapshot_dir, "snapshot_file")
    mem_path = Path.join(snapshot_dir, "mem_file")

    # retry snapshot load — the API socket file may appear before FC is listening
    retry_api(fn ->
      API.put(api, "/snapshot/load", %{
        "snapshot_path" => snapshot_path,
        "mem_file_path" => mem_path,
        "resume_vm" => true
      })
    end)
  end

  defp retry_api(fun, attempts \\ 20) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} when reason in [:econnrefused, :closed] and attempts > 0 ->
        Process.sleep(100)
        retry_api(fun, attempts - 1)

      other ->
        other
    end
  end

  @impl true
  def restore_from_snapshot(state, snapshot_dir) do
    Logger.info("restoring #{state.name} from snapshot in #{snapshot_dir}")

    # kill old shell
    if state.shell && Process.alive?(state.shell) do
      GenServer.stop(state.shell, :normal)
    end

    # kill old FC process
    if state.fc_port do
      try do
        Port.close(state.fc_port)
      rescue
        ArgumentError -> :ok
      end
    end

    # clean up old sockets and wait until gone (old FC may linger)
    File.rm(state.api_socket_path)
    wait_for_file_gone(state.vsock_uds_path, 5_000)

    # spawn fresh firecracker process
    cmd = "#{state.firecracker_bin} --api-sock #{state.api_socket_path}"

    port =
      Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout])

    state = %{state | fc_port: port, port_exited: false, shell: nil}

    # wait for API socket
    :ok = wait_for_file(state.api_socket_path, 10_000)

    # load snapshot and resume in one call
    :ok = snapshot_load(state, snapshot_dir)

    :ok = wait_for_file(state.vsock_uds_path, 30_000)
    Logger.info("vsock UDS appeared at #{state.vsock_uds_path}")

    # verify FC process is still alive after snapshot load
    case API.get(state.api_socket_path, "/vm") do
      {:ok, body} -> Logger.info("FC alive after restore: #{inspect(body)}")
      {:error, reason} -> Logger.warning("FC API check failed: #{inspect(reason)}")
    end

    # reconnect shell via vsock
    Logger.info("reconnecting shell via vsock for #{state.name}")

    {:ok, shell} =
      Shell.start_link(
        socket_path: state.vsock_uds_path,
        transport: Vsock,
        transport_config: %{uds_path: state.vsock_uds_path, port: state.vsock_port}
      )

    :ok = Shell.wait_for_connection(shell, 120_000)
    state = %{state | shell: shell}

    {:ok, shell, state}
  end

  # network control via host-side ip link commands

  @impl true
  def block(%{tap_interfaces: []}), do: {:error, :unsupported}

  def block(%{tap_interfaces: taps}) do
    Enum.each(taps, fn {_id, host_dev, _mac} ->
      System.cmd("ip", ["link", "set", host_dev, "down"])
    end)

    :ok
  end

  @impl true
  def unblock(%{tap_interfaces: []}), do: {:error, :unsupported}

  def unblock(%{tap_interfaces: taps}) do
    Enum.each(taps, fn {_id, host_dev, _mac} ->
      System.cmd("ip", ["link", "set", host_dev, "up"])
    end)

    :ok
  end

  @impl true
  def handle_port_exit(state, _code) do
    %{state | port_exited: true, fc_port: nil}
  end

  @impl true
  def capabilities(_state), do: []

  # private helpers

  defp configure_vm(state) do
    api = state.api_socket_path

    # logger (retry — socket file may appear before FC is listening)
    :ok =
      retry_api(fn ->
        API.put(api, "/logger", %{
          "log_path" => state.log_path,
          "level" => state.log_level,
          "show_level" => true,
          "show_log_origin" => true
        })
      end)

    # machine config
    machine_config =
      %{
        "vcpu_count" => state.vcpu_count,
        "mem_size_mib" => state.mem_size_mib
      }
      |> then(fn cfg ->
        if state.huge_pages, do: Map.put(cfg, "huge_pages", state.huge_pages), else: cfg
      end)

    :ok = API.put(api, "/machine-config", machine_config)

    # boot source
    boot_source = %{
      "kernel_image_path" => state.kernel_image_path,
      "boot_args" => state.kernel_boot_args
    }

    boot_source =
      if state.initrd_path,
        do: Map.put(boot_source, "initrd_path", state.initrd_path),
        else: boot_source

    :ok = API.put(api, "/boot-source", boot_source)

    # root drive
    :ok =
      API.put(api, "/drives/rootfs", %{
        "drive_id" => "rootfs",
        "path_on_host" => state.rootfs_path,
        "is_root_device" => true,
        "is_read_only" => false
      })

    # extra drives
    Enum.each(state.extra_drives, fn {drive_id, path, read_only} ->
      :ok =
        API.put(api, "/drives/#{drive_id}", %{
          "drive_id" => drive_id,
          "path_on_host" => path,
          "is_root_device" => false,
          "is_read_only" => read_only
        })
    end)

    # vsock
    :ok =
      API.put(api, "/vsock", %{
        "guest_cid" => state.vsock_cid,
        "uds_path" => state.vsock_uds_path
      })

    # network interfaces
    Enum.each(state.tap_interfaces, fn {iface_id, host_dev, guest_mac} ->
      :ok =
        API.put(api, "/network-interfaces/#{iface_id}", %{
          "iface_id" => iface_id,
          "host_dev_name" => host_dev,
          "guest_mac" => guest_mac
        })
    end)

    # entropy device (virtio-rng)
    if state.entropy do
      :ok = API.put(api, "/entropy", %{})
    end

    :ok
  end

  defp wait_for_file_gone(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_file_gone(path, deadline)
  end

  defp do_wait_for_file_gone(path, deadline) do
    if File.exists?(path) do
      File.rm(path)

      if System.monotonic_time(:millisecond) >= deadline do
        :ok
      else
        Process.sleep(50)
        do_wait_for_file_gone(path, deadline)
      end
    else
      :ok
    end
  end

  defp wait_for_file(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_file(path, deadline)
  end

  defp do_wait_for_file(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, {:file_timeout, path}}
      else
        Process.sleep(50)
        do_wait_for_file(path, deadline)
      end
    end
  end

  defp wait_for_process_exit(%{fc_port: nil}, _timeout), do: :ok
  defp wait_for_process_exit(%{port_exited: true}, _timeout), do: :ok

  defp wait_for_process_exit(%{fc_port: port}, timeout) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end
end
