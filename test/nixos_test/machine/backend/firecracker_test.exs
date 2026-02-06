defmodule NixosTest.Machine.Backend.FirecrackerTest do
  use ExUnit.Case

  alias NixosTest.Machine.Backend.Firecracker

  describe "init/1" do
    test "stores config and derives socket paths" do
      config = %{
        name: "test-fc",
        firecracker_bin: "/usr/bin/firecracker",
        kernel_image_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4",
        state_dir: "/tmp/fc-test-#{:rand.uniform(100_000)}",
        vcpu_count: 2,
        mem_size_mib: 512,
        vsock_cid: 3,
        vsock_port: 1234
      }

      assert {:ok, state} = Firecracker.init(config)
      assert state.name == "test-fc"
      assert state.api_socket_path == "#{config.state_dir}/firecracker.sock"
      assert state.vsock_uds_path == "#{config.state_dir}/v.sock"
    end
  end

  describe "capabilities/1" do
    test "returns empty list (no VGA, QMP, or SLIRP)" do
      config = %{
        name: "cap-test",
        state_dir: "/tmp/fc-cap-test"
      }

      {:ok, state} = Firecracker.init(config)
      assert Firecracker.capabilities(state) == []
    end
  end

  describe "unsupported operations" do
    setup do
      config = %{name: "unsupported-test", state_dir: "/tmp/fc-unsupported"}
      {:ok, state} = Firecracker.init(config)
      %{state: state}
    end

    test "screenshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Firecracker.screenshot(state, "test.ppm")
    end

    test "send_key returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Firecracker.send_key(state, "ctrl-alt-delete")
    end

    test "forward_port returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Firecracker.forward_port(state, 8080, 80)
    end

    test "send_console returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Firecracker.send_console(state, "hello")
    end
  end

  describe "block/unblock" do
    test "block without tap interfaces returns unsupported" do
      config = %{name: "block-test", state_dir: "/tmp/fc-block", tap_interfaces: []}
      {:ok, state} = Firecracker.init(config)
      assert {:error, :unsupported} = Firecracker.block(state)
    end

    test "unblock without tap interfaces returns unsupported" do
      config = %{name: "unblock-test", state_dir: "/tmp/fc-unblock", tap_interfaces: []}
      {:ok, state} = Firecracker.init(config)
      assert {:error, :unsupported} = Firecracker.unblock(state)
    end
  end

  describe "handle_port_exit/2" do
    test "marks port as exited" do
      config = %{name: "exit-test", state_dir: "/tmp/fc-exit"}
      {:ok, state} = Firecracker.init(config)
      new_state = Firecracker.handle_port_exit(state, 0)
      assert new_state.port_exited == true
      assert new_state.fc_port == nil
    end
  end
end
