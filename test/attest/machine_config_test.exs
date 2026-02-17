defmodule Attest.MachineConfigTest do
  use ExUnit.Case, async: true

  alias Attest.MachineConfig

  describe "parse_file/2" do
    test "parses QEMU machine config from JSON" do
      json =
        Jason.encode!(%{
          "machines" => [
            %{
              "name" => "server",
              "backend" => "qemu",
              "start_command" => "/nix/store/abc/bin/run-server-vm"
            }
          ],
          "vlans" => [1, 2],
          "global_timeout" => 1800
        })

      path = write_tmp_json(json)
      config = MachineConfig.parse_file(path, state_dir: "/tmp/state")

      assert config.vlans == [1, 2]
      assert config.global_timeout == 1_800_000

      [machine] = config.machines
      assert machine.name == "server"
      assert machine.backend == Attest.Machine.Backend.QEMU
      assert machine.start_command =~ "run-server-vm"
      assert machine.qmp_socket_path =~ "/tmp/state"
      assert machine.shell_socket_path =~ "/tmp/state"
    end

    test "QEMU name from JSON overrides script-derived name" do
      # node key is "web" but script has hostname "webserver"
      json =
        Jason.encode!(%{
          "machines" => [
            %{
              "name" => "web",
              "backend" => "qemu",
              "start_command" => "/nix/store/abc/bin/run-webserver-vm"
            }
          ]
        })

      path = write_tmp_json(json)
      config = MachineConfig.parse_file(path, state_dir: "/tmp/state")

      [machine] = config.machines
      # name should be the JSON name, not derived from script
      assert machine.name == "web"
      # state dir should use the JSON name
      assert machine.state_dir =~ "vm-state-web"
      # but the start command should still reference the original script
      assert machine.start_command =~ "run-webserver-vm"
    end

    test "parses firecracker machine config from JSON" do
      json =
        Jason.encode!(%{
          "machines" => [
            %{
              "name" => "node",
              "backend" => "firecracker",
              "firecracker_bin" => "/nix/store/fc/bin/firecracker",
              "kernel_image_path" => "/nix/store/vmlinux",
              "rootfs_path" => "/nix/store/rootfs.ext4",
              "initrd_path" => "/nix/store/initrd",
              "kernel_boot_args" => "console=ttyS0 panic=1",
              "vsock_cid" => 3,
              "vsock_port" => 1234,
              "mem_size_mib" => 512,
              "vcpu_count" => 1
            }
          ]
        })

      path = write_tmp_json(json)
      config = MachineConfig.parse_file(path, state_dir: "/tmp/state")

      [machine] = config.machines
      assert machine.name == "node"
      assert machine.backend == Attest.Machine.Backend.Firecracker
      assert machine.firecracker_bin == "/nix/store/fc/bin/firecracker"
      assert machine.kernel_image_path == "/nix/store/vmlinux"
      assert machine.rootfs_path =~ "/tmp/state"
      assert machine.initrd_path == "/nix/store/initrd"
      assert machine.state_dir =~ "/tmp/state"
    end

    test "firecracker rootfs is copied to writable state_dir" do
      # firecracker modifies rootfs in-place, so it must be copied
      # from the nix store to a writable location
      json =
        Jason.encode!(%{
          "machines" => [
            %{
              "name" => "fc",
              "backend" => "firecracker",
              "firecracker_bin" => "/bin/false",
              "kernel_image_path" => "/bin/false",
              "rootfs_path" => "/nix/store/original-rootfs.ext4",
              "vsock_cid" => 3,
              "vsock_port" => 1234
            }
          ]
        })

      path = write_tmp_json(json)
      config = MachineConfig.parse_file(path, state_dir: "/tmp/state")

      [machine] = config.machines
      # rootfs_path should point to state_dir, not nix store
      refute machine.rootfs_path =~ "/nix/store"
      assert machine.rootfs_path =~ "/tmp/state"
      # original path preserved for copying
      assert machine.rootfs_source == "/nix/store/original-rootfs.ext4"
    end

    test "multiple machines of mixed backends" do
      json =
        Jason.encode!(%{
          "machines" => [
            %{
              "name" => "qemu-node",
              "backend" => "qemu",
              "start_command" => "/nix/store/x/bin/run-qemu-node-vm"
            },
            %{
              "name" => "fc-node",
              "backend" => "firecracker",
              "firecracker_bin" => "/bin/fc",
              "kernel_image_path" => "/vmlinux",
              "rootfs_path" => "/rootfs.ext4",
              "vsock_cid" => 3,
              "vsock_port" => 1234
            }
          ]
        })

      path = write_tmp_json(json)
      config = MachineConfig.parse_file(path, state_dir: "/tmp/state")

      assert length(config.machines) == 2
      [qemu, fc] = config.machines
      assert qemu.backend == Attest.Machine.Backend.QEMU
      assert fc.backend == Attest.Machine.Backend.Firecracker
    end

    test "defaults vlans to empty and timeout to 3600s" do
      json = Jason.encode!(%{"machines" => []})
      path = write_tmp_json(json)
      config = MachineConfig.parse_file(path, state_dir: "/tmp/state")

      assert config.vlans == []
      assert config.global_timeout == 3_600_000
    end
  end

  defp write_tmp_json(json) do
    path = Path.join(System.tmp_dir!(), "mc-test-#{:rand.uniform(100_000)}.json")
    File.write!(path, json)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
