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

  use Attest.Machine.Backend.MicroVM

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
    :tap_interfaces,
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
       tap_interfaces: Map.get(config, :tap_interfaces, []),
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

    # connect shell via vsock
    connect_shell(state)
  end

  @impl true
  def shutdown(%{shell: nil} = state, timeout) do
    Logger.warning("shutdown on #{state.name}: no shell, using halt")
    halt(state, timeout)
  end

  def shutdown(%{shell: shell} = state, timeout) do
    Logger.info("shutting down #{state.name}")

    # reboot -f -p: force immediate power-off (no ACPI needed)
    case Shell.execute(shell, "reboot -f -p") do
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
            close_port(state.ch_port)
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
    stop_shell(state.shell)
    close_port(state.ch_port)
    File.rm(state.api_socket_path)
    File.rm(state.vsock_uds_path)
    :ok
  end

  # snapshots

  @impl true
  def snapshot_create(state, snapshot_dir) do
    api = state.api_socket_path
    File.mkdir_p!(snapshot_dir)

    with :ok <- API.put_no_body(api, "/api/v1/vm.pause") do
      API.put(api, "/api/v1/vm.snapshot", %{
        "destination_url" => "file://#{snapshot_dir}"
      })
    end
  end

  @impl true
  def snapshot_load(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def restore_from_snapshot(state, snapshot_dir) do
    Logger.info("restoring #{state.name} from snapshot in #{snapshot_dir}")

    # tear down existing CH process and shell
    stop_shell(state.shell)
    close_port(state.ch_port)
    File.rm(state.api_socket_path)
    Backend.wait_for_file_gone(state.vsock_uds_path, 5_000)

    state = spawn_and_restore(state, snapshot_dir)
    connect_shell(state)
  end

  defp spawn_and_restore(state, snapshot_dir) do
    File.rm(state.api_socket_path)
    File.rm(state.vsock_uds_path)

    cmd = "#{state.cloud_hypervisor_bin} --api-socket #{state.api_socket_path}"
    port = Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout])
    state = %{state | ch_port: port, port_exited: false, shell: nil}

    :ok = wait_for_file(state.api_socket_path, 10_000)

    :ok =
      retry_api(fn ->
        API.put(state.api_socket_path, "/api/v1/vm.restore", %{
          "source_url" => "file://#{snapshot_dir}"
        })
      end)

    :ok =
      retry_api(fn ->
        API.put_no_body(state.api_socket_path, "/api/v1/vm.resume")
      end)

    state
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
  def handle_port_exit(state, _code) do
    %{state | port_exited: true, ch_port: nil}
  end

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
    |> maybe_put_net(state.tap_interfaces)
  end

  # private helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_net(map, []), do: map

  defp maybe_put_net(map, taps) do
    net =
      Enum.map(taps, fn {_iface_id, host_dev, mac} ->
        %{"tap" => host_dev, "mac" => mac}
      end)

    Map.put(map, "net", net)
  end

  defp wait_for_process_exit(state, timeout),
    do: Backend.wait_for_process_exit(state.ch_port, state.port_exited, timeout)
end
