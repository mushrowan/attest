defmodule Attest.MachineConfig do
  @moduledoc """
  Parses backend-agnostic JSON machine configs into Driver-compatible maps

  The JSON format supports QEMU, Firecracker, and Cloud Hypervisor backends.
  For microVM backends (FC/CH), rootfs is copied to a writable location and
  optional fields are merged from JSON keys to atom-keyed maps.
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

    script
    |> StartCommand.build(state_dir: state_dir, name: name)
    |> StartCommand.to_machine_config()
  end

  defp parse_machine(%{"backend" => "firecracker"} = m, state_dir) do
    {base, m} = microvm_base(m, state_dir, "firecracker")

    fc_base = %{
      firecracker_bin: Map.fetch!(m, "firecracker_bin")
    }

    fc_optionals = pick_optional_fields(m, [:huge_pages, :entropy])

    extra_drives =
      case Map.get(m, "store_image_path") do
        nil -> %{}
        path -> %{extra_drives: [{"store", path, true}]}
      end

    snapshot =
      case Map.get(m, "snapshot_path") do
        nil -> %{}
        path -> %{snapshot_path: path}
      end

    base
    |> Map.merge(fc_base)
    |> Map.merge(
      pick_optional_fields(m, [:initrd_path, :kernel_boot_args, :mem_size_mib, :vcpu_count])
    )
    |> Map.merge(fc_optionals)
    |> Map.merge(extra_drives)
    |> Map.merge(parse_tap_interfaces(m))
    |> Map.merge(snapshot)
  end

  defp parse_machine(%{"backend" => "cloud-hypervisor"} = m, state_dir) do
    {base, m} = microvm_base(m, state_dir, "cloud-hypervisor")

    ch_base = %{
      cloud_hypervisor_bin: Map.fetch!(m, "cloud_hypervisor_bin")
    }

    extra_disks =
      case Map.get(m, "store_image_path") do
        nil -> %{}
        path -> %{extra_disks: [%{"path" => path, "readonly" => true}]}
      end

    base
    |> Map.merge(ch_base)
    |> Map.merge(
      pick_optional_fields(m, [:initrd_path, :kernel_boot_args, :mem_size_mib, :vcpu_count])
    )
    |> Map.merge(extra_disks)
    |> Map.merge(parse_tap_interfaces(m))
  end

  defp parse_machine(%{"backend" => backend}, _state_dir) do
    raise ArgumentError, "unsupported backend: #{backend}"
  end

  defp parse_machine(m, _state_dir) do
    raise ArgumentError, "machine config missing 'backend' field: #{inspect(m)}"
  end

  # shared base for FC and CH: name, backend module, paths, vsock config
  defp microvm_base(m, state_dir, backend_key) do
    name = Map.fetch!(m, "name")
    node_state_dir = Path.join(state_dir, name)
    rootfs_source = Map.fetch!(m, "rootfs_path")
    rootfs_dest = Path.join(node_state_dir, "rootfs.ext4")

    base = %{
      name: name,
      backend: @backend_map[backend_key],
      kernel_image_path: Map.fetch!(m, "kernel_image_path"),
      rootfs_path: rootfs_dest,
      rootfs_source: rootfs_source,
      state_dir: node_state_dir,
      vsock_cid: Map.get(m, "vsock_cid", 3),
      vsock_port: Map.get(m, "vsock_port", 1234)
    }

    {base, m}
  end

  defp pick_optional_fields(m, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case Map.get(m, Atom.to_string(field)) do
        nil -> acc
        val -> Map.put(acc, field, val)
      end
    end)
  end

  defp parse_tap_interfaces(m) do
    case Map.get(m, "tap_interfaces") do
      nil ->
        %{}

      taps when is_list(taps) ->
        parsed = Enum.map(taps, fn [id, dev, mac] -> {id, dev, mac} end)
        %{tap_interfaces: parsed}
    end
  end
end
