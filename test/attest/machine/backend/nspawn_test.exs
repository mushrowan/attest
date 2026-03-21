defmodule Attest.Machine.Backend.NspawnTest do
  use ExUnit.Case

  alias Attest.Machine.Backend.Nspawn

  describe "init/1" do
    test "stores config and derives socket path" do
      config = %{
        name: "test-container",
        rootfs_path: "/nix/store/abc-nixos-rootfs",
        state_dir: "/tmp/nspawn-test"
      }

      assert {:ok, state} = Nspawn.init(config)
      assert state.name == "test-container"
      assert state.rootfs_path == "/nix/store/abc-nixos-rootfs"
      assert state.state_dir == "/tmp/nspawn-test"
      assert state.shell_socket_path == "/tmp/nspawn-test/shell.sock"
    end

    test "uses defaults for optional fields" do
      config = %{name: "defaults", rootfs_path: "/rootfs", state_dir: "/tmp/nspawn-defaults"}
      {:ok, state} = Nspawn.init(config)
      assert state.bind_dirs == []
      assert state.nspawn_extra_args == []
    end

    test "stores bind_dirs when set" do
      config = %{
        name: "binds",
        rootfs_path: "/rootfs",
        state_dir: "/tmp/nspawn-binds",
        bind_dirs: [{"/host/path", "/container/path"}]
      }

      {:ok, state} = Nspawn.init(config)
      assert state.bind_dirs == [{"/host/path", "/container/path"}]
    end
  end

  describe "capabilities/1" do
    test "returns empty list" do
      {:ok, state} = Nspawn.init(%{name: "cap", rootfs_path: "/r", state_dir: "/tmp/nspawn-cap"})
      assert Nspawn.capabilities(state) == []
    end
  end

  describe "unsupported operations" do
    setup do
      {:ok, state} =
        Nspawn.init(%{name: "unsup", rootfs_path: "/r", state_dir: "/tmp/nspawn-unsup"})

      %{state: state}
    end

    test "screenshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.screenshot(state, "test.ppm")
    end

    test "send_key returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.send_key(state, "ret")
    end

    test "forward_port returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.forward_port(state, 8080, 80)
    end

    test "send_console returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.send_console(state, "hi")
    end

    test "block returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.block(state)
    end

    test "unblock returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.unblock(state)
    end

    test "snapshot_create returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.snapshot_create(state, "/tmp")
    end

    test "snapshot_load returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.snapshot_load(state, "/tmp")
    end

    test "restore_from_snapshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = Nspawn.restore_from_snapshot(state, "/tmp")
    end
  end

  describe "handle_port_exit/2" do
    test "marks port as exited" do
      {:ok, state} =
        Nspawn.init(%{name: "exit", rootfs_path: "/r", state_dir: "/tmp/nspawn-exit"})

      new_state = Nspawn.handle_port_exit(state, 0)
      assert new_state.port_exited == true
      assert new_state.nspawn_port == nil
    end
  end

  describe "nspawn_cmd/1" do
    test "builds basic command" do
      {:ok, state} =
        Nspawn.init(%{
          name: "cmd-test",
          rootfs_path: "/nix/store/abc-rootfs",
          state_dir: "/tmp/nspawn-cmd"
        })

      cmd = Nspawn.nspawn_cmd(state)
      assert cmd =~ "systemd-nspawn"
      assert cmd =~ "--boot"
      assert cmd =~ "--directory=/nix/store/abc-rootfs"
      assert cmd =~ "--machine=cmd-test"
      assert cmd =~ "--bind=/tmp/nspawn-cmd:/run/attest"
    end

    test "includes extra bind dirs" do
      {:ok, state} =
        Nspawn.init(%{
          name: "bind-test",
          rootfs_path: "/rootfs",
          state_dir: "/tmp/nspawn-bind",
          bind_dirs: [{"/host/a", "/guest/a"}, {"/host/b", "/guest/b"}]
        })

      cmd = Nspawn.nspawn_cmd(state)
      assert cmd =~ "--bind=/host/a:/guest/a"
      assert cmd =~ "--bind=/host/b:/guest/b"
    end

    test "includes extra args" do
      {:ok, state} =
        Nspawn.init(%{
          name: "args-test",
          rootfs_path: "/rootfs",
          state_dir: "/tmp/nspawn-args",
          nspawn_extra_args: ["--private-network", "--capability=CAP_NET_ADMIN"]
        })

      cmd = Nspawn.nspawn_cmd(state)
      assert cmd =~ "--private-network"
      assert cmd =~ "--capability=CAP_NET_ADMIN"
    end
  end
end
