defmodule NixosTest.Machine.Backend.CloudHypervisor do
  @moduledoc """
  Cloud Hypervisor backend

  Manages cloud-hypervisor microVM lifecycle via its REST API over
  a unix socket. Uses virtconsole (hvc0) for the shell backdoor,
  same as QEMU — the console is exposed as a unix socket.

  ## Capabilities

  No VGA, screenshots, or keyboard simulation. Network block/unblock
  not yet implemented (needs TAP interface management like firecracker).

  ## Config

  Required keys:
  - `:name` — machine name
  - `:cloud_hypervisor_bin` — path to cloud-hypervisor binary
  - `:kernel_image_path` — path to uncompressed vmlinux
  - `:rootfs_path` — path to disk image (raw/qcow2)
  - `:state_dir` — working directory for sockets and logs

  Optional keys:
  - `:initrd_path` — path to initrd (default: nil)
  - `:kernel_boot_args` — kernel command line (default: "console=hvc0 reboot=k panic=1")
  - `:vcpu_count` — number of vCPUs (default: 1)
  - `:mem_size_mib` — memory in MiB (default: 256)
  """

  @behaviour NixosTest.Machine.Backend

  require Logger

  # reuse the HTTP/1.1-over-UDS client from firecracker
  alias NixosTest.Machine.Backend.Firecracker.API
  alias NixosTest.Machine.Shell
  alias NixosTest.Machine.Shell.Transport.VirtConsole

  defstruct [
    :name,
    :cloud_hypervisor_bin,
    :kernel_image_path,
    :rootfs_path,
    :initrd_path,
    :kernel_boot_args,
    :vcpu_count,
    :mem_size_mib,
    :state_dir,
    :api_socket_path,
    :console_socket_path,
    :ch_port,
    :shell,
    port_exited: false
  ]

  @default_boot_args "console=hvc0 reboot=k panic=1"

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
       state_dir: state_dir,
       api_socket_path: Path.join(state_dir, "cloud-hypervisor.sock"),
       console_socket_path: Path.join(state_dir, "console.sock")
     }}
  end

  @impl true
  def start(state) do
    File.mkdir_p!(state.state_dir)
    File.rm(state.api_socket_path)
    File.rm(state.console_socket_path)

    # start the console listener before spawning CH
    # (CH connects TO the socket, so we must be listening first)
    Logger.info("starting console listener for #{state.name}")

    {:ok, shell} =
      Shell.start_link(
        socket_path: state.console_socket_path,
        transport: VirtConsole,
        transport_config: %{socket_path: state.console_socket_path}
      )

    # spawn cloud-hypervisor process
    Logger.info("spawning cloud-hypervisor for #{state.name}")

    cmd =
      "#{state.cloud_hypervisor_bin} --api-socket #{state.api_socket_path}"

    port =
      Port.open({:spawn, cmd}, [:binary, :exit_status, :stderr_to_stdout])

    state = %{state | ch_port: port, shell: shell}

    # wait for API socket
    :ok = wait_for_file(state.api_socket_path, 10_000)

    # create and boot VM via REST API
    Logger.info("creating cloud-hypervisor VM #{state.name}")
    vm_config = build_vm_config(state)
    :ok = API.put(state.api_socket_path, "/api/v1/vm.create", vm_config)

    Logger.info("booting cloud-hypervisor VM #{state.name}")
    :ok = API.put(state.api_socket_path, "/api/v1/vm.boot", %{})

    # wait for shell backdoor connection
    Logger.info("waiting for shell connection for #{state.name}")
    :ok = Shell.wait_for_connection(shell, 120_000)

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
      API.put(state.api_socket_path, "/api/v1/vm.power-button", %{})
    end

    case wait_for_process_exit(state, div(timeout, 2)) do
      :ok ->
        cleanup(state)
        :ok

      {:error, :timeout} ->
        # force kill via VMM shutdown
        if File.exists?(state.api_socket_path) do
          API.put(state.api_socket_path, "/api/v1/vmm.shutdown", %{})
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
    File.rm(state.console_socket_path)

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
      "disks" => [
        %{"path" => state.rootfs_path}
      ],
      "serial" => %{"mode" => "Null"},
      "console" => %{
        "mode" => "Socket",
        "socket" => state.console_socket_path
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
