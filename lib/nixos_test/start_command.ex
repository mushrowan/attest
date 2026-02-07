defmodule NixosTest.StartCommand do
  @moduledoc """
  Parses nix-generated VM start scripts and builds the full QEMU command

  Nix builds a `run-<name>-vm` script for each test node that sets up disks,
  shared directories, and execs QEMU. The driver needs to append runtime args
  for QMP, shell (virtconsole), and serial output.

  This module bridges the gap: given a start script path, it produces a
  complete command string and socket paths that Backend.QEMU expects.
  """

  @name_regex ~r/run-(.+)-vm$/

  @type t :: %{
          name: String.t(),
          start_command: String.t(),
          qmp_socket_path: String.t(),
          shell_socket_path: String.t(),
          state_dir: String.t(),
          shared_dir: String.t()
        }

  @doc """
  Extract the machine name from a nix start script path

  The path follows the pattern `.../bin/run-<name>-vm`.
  """
  @spec name(String.t()) :: String.t()
  def name(script_path) do
    basename = Path.basename(script_path)

    case Regex.run(@name_regex, basename) do
      [_, machine_name] ->
        machine_name

      nil ->
        raise ArgumentError,
              "cannot extract machine name from #{script_path}, expected run-<name>-vm"
    end
  end

  @doc """
  Build a complete start command config from a nix start script

  ## Options

  - `:state_dir` (required) — base directory for VM state
  - `:name` — override machine name (default: extracted from script path)
  - `:allow_reboot` — if true, omits `-no-reboot` (default: false)
  """
  @spec build(String.t(), keyword()) :: t()
  def build(script_path, opts) do
    machine_name = Keyword.get(opts, :name) || name(script_path)
    base_state_dir = Keyword.fetch!(opts, :state_dir)
    allow_reboot = Keyword.get(opts, :allow_reboot, false)

    state_dir = Path.join(base_state_dir, "vm-state-#{machine_name}")
    qmp_socket = Path.join(state_dir, "qmp")
    shell_socket = Path.join(state_dir, "shell")
    shared_dir = Path.join(state_dir, "shared")

    runtime_args =
      [
        "-qmp unix:#{qmp_socket},server=on,wait=off",
        "-chardev socket,id=shell,path=#{shell_socket}",
        "-device virtio-serial",
        "-device virtconsole,chardev=shell",
        "-nographic"
      ]
      |> maybe_add_no_reboot(allow_reboot)

    disk_image = Path.join(state_dir, "#{machine_name}.qcow2")

    env_prefix =
      "env TMPDIR=#{state_dir} USE_TMPDIR=1 SHARED_DIR=#{shared_dir} NIX_DISK_IMAGE=#{disk_image}"

    command =
      "#{env_prefix} #{script_path} #{Enum.join(runtime_args, " ")}"

    %{
      name: machine_name,
      start_command: command,
      qmp_socket_path: qmp_socket,
      shell_socket_path: shell_socket,
      state_dir: state_dir,
      shared_dir: shared_dir
    }
  end

  @doc """
  Convert a build result to a Machine config map

  Returns a map suitable for passing to `Driver.start_link(machines: [config])`.
  """
  @spec to_machine_config(t()) :: map()
  def to_machine_config(build_result) do
    %{
      name: build_result.name,
      backend: NixosTest.Machine.Backend.QEMU,
      start_command: build_result.start_command,
      qmp_socket_path: build_result.qmp_socket_path,
      shell_socket_path: build_result.shell_socket_path,
      state_dir: build_result.state_dir,
      shared_dir: build_result.shared_dir
    }
  end

  defp maybe_add_no_reboot(args, true), do: args
  defp maybe_add_no_reboot(args, false), do: args ++ ["-no-reboot"]
end
