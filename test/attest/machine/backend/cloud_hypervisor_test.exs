defmodule Attest.Machine.Backend.CloudHypervisorTest do
  use ExUnit.Case

  alias Attest.Machine.Backend.CloudHypervisor

  describe "init/1" do
    test "stores config and derives socket paths" do
      config = %{
        name: "test-ch",
        cloud_hypervisor_bin: "/usr/bin/cloud-hypervisor",
        kernel_image_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.raw",
        state_dir: "/tmp/ch-test"
      }

      assert {:ok, state} = CloudHypervisor.init(config)
      assert state.name == "test-ch"
      assert state.api_socket_path == "/tmp/ch-test/cloud-hypervisor.sock"
      assert state.vsock_uds_path == "/tmp/ch-test/v.sock"
    end

    test "uses defaults for optional fields" do
      config = %{name: "defaults", state_dir: "/tmp/ch-defaults"}
      {:ok, state} = CloudHypervisor.init(config)
      assert state.vcpu_count == 1
      assert state.mem_size_mib == 256
      assert state.vsock_cid == 3
      assert state.vsock_port == 1234
    end
  end

  describe "capabilities/1" do
    test "returns empty list (no VGA or keyboard)" do
      {:ok, state} = CloudHypervisor.init(%{name: "cap", state_dir: "/tmp/ch-cap"})
      assert CloudHypervisor.capabilities(state) == []
    end
  end

  describe "unsupported operations" do
    setup do
      {:ok, state} = CloudHypervisor.init(%{name: "unsup", state_dir: "/tmp/ch-unsup"})
      %{state: state}
    end

    test "screenshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.screenshot(state, "test.ppm")
    end

    test "send_key returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.send_key(state, "ret")
    end

    test "forward_port returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.forward_port(state, 8080, 80)
    end

    test "send_console returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.send_console(state, "hi")
    end

    test "snapshot_create returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.snapshot_create(state, "/tmp")
    end

    test "snapshot_load returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.snapshot_load(state, "/tmp")
    end

    test "restore_from_snapshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.restore_from_snapshot(state, "/tmp")
    end
  end

  describe "handle_port_exit/2" do
    test "marks port as exited" do
      {:ok, state} = CloudHypervisor.init(%{name: "exit", state_dir: "/tmp/ch-exit"})
      new_state = CloudHypervisor.handle_port_exit(state, 0)
      assert new_state.port_exited == true
      assert new_state.ch_port == nil
    end
  end

  describe "build_vm_config/1" do
    test "produces valid cloud-hypervisor VmConfig JSON" do
      {:ok, state} =
        CloudHypervisor.init(%{
          name: "cfg-test",
          kernel_image_path: "/vmlinux",
          rootfs_path: "/rootfs.ext4",
          initrd_path: "/initrd",
          kernel_boot_args: "console=ttyS0",
          vcpu_count: 2,
          mem_size_mib: 512,
          state_dir: "/tmp/ch-cfg"
        })

      config = CloudHypervisor.build_vm_config(state)

      assert config["payload"]["kernel"] == "/vmlinux"
      assert config["payload"]["initramfs"] == "/initrd"
      assert config["payload"]["cmdline"] == "console=ttyS0"
      assert config["cpus"]["boot_vcpus"] == 2
      assert config["memory"]["size"] == 512 * 1024 * 1024
      assert hd(config["disks"])["path"] == "/rootfs.ext4"
      assert config["serial"]["mode"] == "Null"
    end

    test "includes vsock config" do
      {:ok, state} =
        CloudHypervisor.init(%{
          name: "vsock-cfg",
          kernel_image_path: "/vmlinux",
          state_dir: "/tmp/ch-vsock-cfg"
        })

      config = CloudHypervisor.build_vm_config(state)

      assert config["vsock"]["cid"] == 3
      assert config["vsock"]["socket"] == "/tmp/ch-vsock-cfg/v.sock"
    end

    test "omits initramfs when nil" do
      {:ok, state} =
        CloudHypervisor.init(%{
          name: "no-initrd",
          kernel_image_path: "/vmlinux",
          state_dir: "/tmp/ch-no-initrd"
        })

      config = CloudHypervisor.build_vm_config(state)
      refute Map.has_key?(config["payload"], "initramfs")
    end
  end
end
