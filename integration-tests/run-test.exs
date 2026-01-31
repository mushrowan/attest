# integration test: full VM lifecycle
# boot -> execute -> wait_for_unit -> stop

Logger.configure(level: :info)

defmodule IntegrationTest do
  require Logger

  def run do
    vm_script = System.get_env("VM_SCRIPT") || raise "VM_SCRIPT not set"
    state_dir = System.get_env("STATE_DIR") || raise "STATE_DIR not set"

    qmp_path = Path.join(state_dir, "qmp")
    shell_path = Path.join(state_dir, "shell")

    # QEMU args for shell backdoor and QMP
    qemu_args =
      [
        "-qmp",
        "unix:#{qmp_path},server=on,wait=off",
        "-chardev",
        "socket,id=shell,path=#{shell_path}",
        "-device",
        "virtio-serial",
        "-device",
        "virtconsole,chardev=shell",
        "-nographic",
        "-no-reboot"
      ]
      |> Enum.join(" ")

    start_command = "#{vm_script} #{qemu_args}"

    Logger.info("starting VM with command: #{start_command}")

    {:ok, machine} =
      NixosTest.Machine.start_link(
        name: "integration-test",
        start_command: start_command,
        qmp_socket_path: qmp_path,
        shell_socket_path: shell_path
      )

    try do
      # boot VM (5 min timeout handled by Machine.start)
      Logger.info("booting VM...")
      :ok = NixosTest.Machine.start(machine)
      Logger.info("VM booted, shell connected")

      # test execute
      Logger.info("testing execute...")
      {exit_code, output} = NixosTest.Machine.execute(machine, "echo hello-from-vm")
      Logger.info("execute result: exit=#{exit_code}, output=#{inspect(output)}")

      if exit_code != 0 do
        raise "execute failed with exit code #{exit_code}"
      end

      if not String.contains?(output, "hello-from-vm") do
        raise "unexpected output: #{inspect(output)}"
      end

      # test wait_for_unit
      Logger.info("waiting for multi-user.target...")
      :ok = NixosTest.Machine.wait_for_unit(machine, "multi-user.target", 60_000)
      Logger.info("multi-user.target is active")

      # test shutdown via QMP
      Logger.info("shutting down via QMP...")
      :ok = NixosTest.Machine.stop(machine)
      Logger.info("shutdown command sent")

      Logger.info("=== ALL TESTS PASSED ===")
      :ok
    rescue
      e ->
        Logger.error("test failed: #{inspect(e)}")
        # try to stop machine on failure
        try do
          NixosTest.Machine.stop(machine)
        rescue
          _ -> :ok
        end

        reraise e, __STACKTRACE__
    end
  end
end

IntegrationTest.run()
