defmodule Attest.MachineConfig do
  @moduledoc """
  Parses backend-agnostic JSON machine configs into Driver-compatible maps

  The JSON format supports both QEMU and Firecracker backends:

      {
        "machines": [
          {"name": "server", "backend": "qemu", "start_command": "..."},
          {"name": "client", "backend": "firecracker", "firecracker_bin": "...", ...}
        ],
        "vlans": [1, 2],
        "global_timeout": 3600
      }

  For QEMU machines, `start_command` is the path to the nix-generated
  `run-<name>-vm` script. The module uses `StartCommand.build` to
  generate the full QEMU command with QMP and shell sockets.

  For Firecracker machines, all backend-specific fields are passed
  through. The rootfs is copied to a writable location since
  firecracker modifies it in-place.
  """

  require Logger

  alias Attest.StartCommand

  @type parsed_config :: %{
          machines: [map()],
          vlans: [non_neg_integer()],
          global_timeout: non_neg_integer()
        }

  @backend_map %{
    "qemu" => Attest.Machine.Backend.QEMU,
    "firecracker" => Attest.Machine.Backend.Firecracker,
    "cloud-hypervisor" => Attest.Machine.Backend.CloudHypervisor,
    "mock" => Attest.Machine.Backend.Mock
  }

  @doc """
  Parse a JSON machine config file

  ## Options

  - `:state_dir` (required) — base directory for VM state files
  """
  @spec parse_file(String.t(), keyword()) :: parsed_config()
  def parse_file(path, opts) do
    state_dir = Keyword.fetch!(opts, :state_dir)
    json = path |> File.read!() |> Jason.decode!()

    machines =
      json
      |> Map.get("machines", [])
      |> Enum.map(&parse_machine(&1, state_dir))

    %{
      machines: machines,
      vlans: Map.get(json, "vlans", []),
      global_timeout: Map.get(json, "global_timeout", 3600) * 1000
    }
  end

  defp parse_machine(%{"backend" => "qemu"} = m, state_dir) do
    name = Map.fetch!(m, "name")
    script = Map.fetch!(m, "start_command")

    # pass name explicitly — the script path uses config.system.name
    # (hostname) which may differ from the node key that test scripts use
    script
    |> StartCommand.build(state_dir: state_dir, name: name)
    |> StartCommand.to_machine_config()
  end

  defp parse_machine(%{"backend" => "firecracker"} = m, state_dir) do
    name = Map.fetch!(m, "name")
    node_state_dir = Path.join(state_dir, name)
    rootfs_source = Map.fetch!(m, "rootfs_path")
    rootfs_dest = Path.join(node_state_dir, "rootfs.ext4")

    base = %{
      name: name,
      backend: @backend_map["firecracker"],
      firecracker_bin: Map.fetch!(m, "firecracker_bin"),
      kernel_image_path: Map.fetch!(m, "kernel_image_path"),
      rootfs_path: rootfs_dest,
      rootfs_source: rootfs_source,
      state_dir: node_state_dir,
      vsock_cid: Map.get(m, "vsock_cid", 3),
      vsock_port: Map.get(m, "vsock_port", 1234)
    }

    optional_fields =
      [:initrd_path, :kernel_boot_args, :mem_size_mib, :vcpu_count]
      |> Enum.reduce(%{}, fn field, acc ->
        key = Atom.to_string(field)

        case Map.get(m, key) do
          nil -> acc
          val -> Map.put(acc, field, val)
        end
      end)

    # if store_image_path is set, add it as a read-only extra drive
    extra_drives =
      case Map.get(m, "store_image_path") do
        nil -> %{}
        path -> %{extra_drives: [{"store", path, true}]}
      end

    # TAP interfaces: [[iface_id, host_dev_name, guest_mac], ...]
    tap_interfaces =
      case Map.get(m, "tap_interfaces") do
        nil ->
          %{}

        taps when is_list(taps) ->
          parsed = Enum.map(taps, fn [id, dev, mac] -> {id, dev, mac} end)
          %{tap_interfaces: parsed}
      end

    base
    |> Map.merge(optional_fields)
    |> Map.merge(extra_drives)
    |> Map.merge(tap_interfaces)
  end

  defp parse_machine(%{"backend" => "cloud-hypervisor"} = m, state_dir) do
    name = Map.fetch!(m, "name")
    node_state_dir = Path.join(state_dir, name)
    rootfs_source = Map.fetch!(m, "rootfs_path")
    rootfs_dest = Path.join(node_state_dir, "rootfs.ext4")

    base = %{
      name: name,
      backend: @backend_map["cloud-hypervisor"],
      cloud_hypervisor_bin: Map.fetch!(m, "cloud_hypervisor_bin"),
      kernel_image_path: Map.fetch!(m, "kernel_image_path"),
      rootfs_path: rootfs_dest,
      rootfs_source: rootfs_source,
      state_dir: node_state_dir,
      vsock_cid: Map.get(m, "vsock_cid", 3),
      vsock_port: Map.get(m, "vsock_port", 1234)
    }

    optional_fields =
      [:initrd_path, :kernel_boot_args, :mem_size_mib, :vcpu_count]
      |> Enum.reduce(%{}, fn field, acc ->
        key = Atom.to_string(field)

        case Map.get(m, key) do
          nil -> acc
          val -> Map.put(acc, field, val)
        end
      end)

    extra_disks =
      case Map.get(m, "store_image_path") do
        nil -> %{}
        path -> %{extra_disks: [%{"path" => path, "readonly" => true}]}
      end

    base |> Map.merge(optional_fields) |> Map.merge(extra_disks)
  end

  defp parse_machine(%{"backend" => backend}, _state_dir) do
    raise ArgumentError, "unsupported backend: #{backend}"
  end

  defp parse_machine(m, _state_dir) do
    raise ArgumentError, "machine config missing 'backend' field: #{inspect(m)}"
  end
end
