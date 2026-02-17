defmodule Attest.StartCommandTest do
  use ExUnit.Case, async: true

  alias Attest.StartCommand

  describe "name/1" do
    test "extracts machine name from nix start script path" do
      assert StartCommand.name("/nix/store/abc-attest-driver/bin/run-server-vm") == "server"
    end

    test "extracts hyphenated machine name" do
      assert StartCommand.name("/nix/store/abc/bin/run-web-server-vm") == "web-server"
    end

    test "raises on invalid path" do
      assert_raise ArgumentError, fn ->
        StartCommand.name("/nix/store/abc/bin/not-a-vm-script")
      end
    end
  end

  describe "build/2" do
    test "returns a map with start_command, socket paths, and state_dir" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/test-state"
        )

      assert result.name == "mynode"
      assert result.state_dir == "/tmp/test-state/vm-state-mynode"
      assert result.qmp_socket_path == "/tmp/test-state/vm-state-mynode/qmp"
      assert result.shell_socket_path == "/tmp/test-state/vm-state-mynode/shell"
      assert result.shared_dir == "/tmp/test-state/vm-state-mynode/shared"
    end

    test "start_command includes the original script path" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "/nix/store/abc/bin/run-mynode-vm"
    end

    test "start_command appends QMP socket arg" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "-qmp unix:/tmp/s/vm-state-mynode/qmp,server=on,wait=off"
    end

    test "start_command appends shell chardev and virtconsole" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "-chardev socket,id=shell,path=/tmp/s/vm-state-mynode/shell"
      assert result.start_command =~ "-device virtio-serial"
      assert result.start_command =~ "-device virtconsole,chardev=shell"
    end

    test "start_command appends -nographic" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "-nographic"
    end

    test "start_command includes -no-reboot by default" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "-no-reboot"
    end

    test "start_command omits -no-reboot when allow_reboot is true" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s",
          allow_reboot: true
        )

      refute result.start_command =~ "-no-reboot"
    end

    test "sets TMPDIR and USE_TMPDIR env vars in command" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "env TMPDIR=/tmp/s/vm-state-mynode"
      assert result.start_command =~ "USE_TMPDIR=1"
    end

    test "sets SHARED_DIR env var in command" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      assert result.start_command =~ "SHARED_DIR=/tmp/s/vm-state-mynode/shared"
    end
  end

  describe "to_machine_config/1" do
    test "converts build result to a machine config map" do
      result =
        StartCommand.build(
          "/nix/store/abc/bin/run-mynode-vm",
          state_dir: "/tmp/s"
        )

      config = StartCommand.to_machine_config(result)

      assert config.name == "mynode"
      assert config.backend == Attest.Machine.Backend.QEMU
      assert config.start_command == result.start_command
      assert config.qmp_socket_path == result.qmp_socket_path
      assert config.shell_socket_path == result.shell_socket_path
      assert config.state_dir == result.state_dir
      assert config.shared_dir == result.shared_dir
    end
  end
end
