defmodule Attest.Machine.Backend.CloudHypervisor do
  @moduledoc """
  Cloud Hypervisor backend

  Manages cloud-hypervisor microVM lifecycle via its REST API over
  a unix socket. Uses vsock for the shell backdoor (same transport
  as firecracker).

  ## Capabilities

  No VGA, screenshots, or keyboard simulation. Network block/unblock
  not yet implemented.

  ## Config

  Required keys:
  - `:name` — machine name
  - `:cloud_hypervisor_bin` — path to cloud-hypervisor binary
  - `:kernel_image_path` — path to uncompressed vmlinux
  - `:rootfs_path` — path to disk image (raw/ext4)
  - `:state_dir` — working directory for sockets and logs

  Optional keys:
  - `:initrd_path` — path to initrd (default: nil)
  - `:kernel_boot_args` — kernel command line (default: "console=ttyS0 reboot=k panic=1")
  - `:vcpu_count` — number of vCPUs (default: 1)
  - `:mem_size_mib` — memory in MiB (default: 256)
  - `:vsock_cid` — guest vsock CID (default: 3)
  - `:vsock_port` — backdoor port (default: 1234)
  """

  @behaviour Attest.Machine.Backend

  require Logger

  # reuse the HTTP/1.1-over-UDS client from firecracker
  alias Attest.Machine.Backend.Firecracker.API
  alias Attest.Machine.Shell
  alias Attest.Machine.Shell.Transport.Vsock

  defstruct [
    :name,
    :cloud_hypervisor_bin,
    :kernel_image_path,
    :rootfs_path,
    :initrd_path,
    :kernel_boot_args,
    :vcpu_count,
    :mem_size_mib,
    :vsock_cid,
    :vsock_port,
    :state_dir,
    :api_socket_path,
    :vsock_uds_path,
    :extra_disks,
    :ch_port,
    :shell,
    port_exited: false
  ]

  @default_boot_args "console=ttyS0 reboot=k panic=1"

  # lifecycle

  @impl true
  def init(config) do
    state_dir = Map.get(config, :state_dir, "/tmp/ch-#{Map.get(config, :name, "unknown")}")

    {:ok,
     %__MODULE__{
       name: Map.get(config, :name, "unknown"),
       cloud_hypervisor_bin: Map.get(config, :cloud_hypervisor_bin),
       kernel_image_path: Map.get(config, :kernel_image_path),
       rootfs_path: Map.get(config, :rootfs_path),
       initrd_path: Map.get(config, :initrd_path),
       kernel_boot_args: Map.get(config, :kernel_boot_args, @default_boot_args),
       vcpu_count: Map.get(config, :vcpu_count, 1),
       mem_size_mib: Map.get(config, :mem_size_mib, 256),
       vsock_cid: Map.get(config, :vsock_cid, 3),
       vsock_port: Map.get(config, :vsock_port, 1234),
       extra_disks: Map.get(config, :extra_disks, []),
       state_dir: state_dir,
       api_socket_path: Path.join(state_dir, "cloud-hypervisor.sock"),
       vsock_uds_path: Path.join(state_dir, "v.sock")
     }}
  end

  @impl true
  def start(state) do
    File.mkdir_p!(state.state_dir)
    File.rm(state.api_socket_path)
    File.rm(state.vsock_uds_path)

    # spawn cloud-hypervisor process
    Logger.info("spawning cloud-hypervisor for #{state.name}")

    cmd = "#{state.cloud_hypervisor_bin} --api-socket #{state.api_socket_path}"

    port =
      Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout])

    state = %{state | ch_port: port}

    # wait for API socket
    :ok = wait_for_file(state.api_socket_path, 10_000)

    # create and boot VM via REST API
    Logger.info("creating cloud-hypervisor VM #{state.name}")
    vm_config = build_vm_config(state)
    :ok = API.put(state.api_socket_path, "/api/v1/vm.create", vm_config)

    Logger.info("booting cloud-hypervisor VM #{state.name}")
    :ok = API.put_no_body(state.api_socket_path, "/api/v1/vm.boot")

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

    case Shell.execute(shell, "poweroff") do
      {:ok, _, _} -> :ok
      {:error, _} -> :ok
    end

    result = wait_for_process_exit(state, timeout)
    cleanup(state)
    result
  end

  @impl true
  def halt(state, timeout) do
    Logger.info("halting #{state.name}")

    # try power button first, then VMM shutdown
    if File.exists?(state.api_socket_path) do
      API.put_no_body(state.api_socket_path, "/api/v1/vm.power-button")
    end

    case wait_for_process_exit(state, div(timeout, 2)) do
      :ok ->
        cleanup(state)
        :ok

      {:error, :timeout} ->
        # force kill via VMM shutdown
        if File.exists?(state.api_socket_path) do
          API.put_no_body(state.api_socket_path, "/api/v1/vmm.shutdown")
        end

        case wait_for_process_exit(state, div(timeout, 4)) do
          :ok ->
            cleanup(state)
            :ok

          {:error, :timeout} ->
            # last resort: close port
            if state.ch_port do
              try do
                Port.close(state.ch_port)
              rescue
                ArgumentError -> :ok
              end
            end

            cleanup(state)
            :ok
        end
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

    if state.ch_port do
      try do
        Port.close(state.ch_port)
      rescue
        ArgumentError -> :ok
      end
    end

    File.rm(state.api_socket_path)
    File.rm(state.vsock_uds_path)

    :ok
  end

  # unsupported — no VGA, QMP, or SLIRP

  @impl true
  def screenshot(_state, _filename), do: {:error, :unsupported}

  @impl true
  def send_key(_state, _key), do: {:error, :unsupported}

  @impl true
  def forward_port(_state, _host_port, _guest_port), do: {:error, :unsupported}

  @impl true
  def send_console(_state, _chars), do: {:error, :unsupported}

  @impl true
  def block(_state), do: {:error, :unsupported}

  @impl true
  def unblock(_state), do: {:error, :unsupported}

  # snapshots not yet implemented
  @impl true
  def snapshot_create(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def snapshot_load(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def restore_from_snapshot(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def handle_port_exit(state, _code) do
    %{state | port_exited: true, ch_port: nil}
  end

  @impl true
  def capabilities(_state), do: []

  # public — used by tests and nix integration

  @doc """
  Build the VmConfig JSON map for the cloud-hypervisor REST API
  """
  @spec build_vm_config(%__MODULE__{}) :: map()
  def build_vm_config(state) do
    payload =
      %{"kernel" => state.kernel_image_path}
      |> maybe_put("initramfs", state.initrd_path)
      |> maybe_put("cmdline", state.kernel_boot_args)

    %{
      "payload" => payload,
      "cpus" => %{
        "boot_vcpus" => state.vcpu_count,
        "max_vcpus" => state.vcpu_count
      },
      "memory" => %{
        "size" => state.mem_size_mib * 1024 * 1024
      },
      "disks" =>
        [%{"path" => state.rootfs_path}] ++
          Enum.map(state.extra_disks, fn disk ->
            %{"path" => disk["path"], "readonly" => Map.get(disk, "readonly", false)}
          end),
      "serial" => %{"mode" => "Null"},
      "console" => %{"mode" => "Off"},
      "vsock" => %{
        "cid" => state.vsock_cid,
        "socket" => state.vsock_uds_path
      }
    }
  end

  # private helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp wait_for_process_exit(%{ch_port: nil}, _timeout), do: :ok
  defp wait_for_process_exit(%{port_exited: true}, _timeout), do: :ok

  defp wait_for_process_exit(%{ch_port: port}, timeout) do
    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      timeout -> {:error, :timeout}
    end
  end
end
