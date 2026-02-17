# integration test: multi-vm
# boot two VMs via Driver, execute commands on both

Logger.configure(level: :info)

defmodule MultiVMTest do
  require Logger

  def run do
    vm_script = System.get_env("VM_SCRIPT") || raise "VM_SCRIPT not set"
    state_dir = System.get_env("STATE_DIR") || raise "STATE_DIR not set"

    # create state dirs for each VM
    vm1_dir = Path.join(state_dir, "vm1")
    vm2_dir = Path.join(state_dir, "vm2")
    File.mkdir_p!(vm1_dir)
    File.mkdir_p!(vm2_dir)

    # build machine configs
    machines = [
      build_machine_config("alice", vm_script, vm1_dir),
      build_machine_config("bob", vm_script, vm2_dir)
    ]

    Logger.info("starting Driver with 2 machines...")

    {:ok, driver} = Attest.Driver.start_link(machines: machines)

    try do
      # start machines sequentially to debug
      Logger.info("booting alice...")
      {:ok, alice} = Attest.Driver.get_machine(driver, "alice")
      :ok = Attest.Machine.start(alice)
      Logger.info("alice booted")

      Logger.info("booting bob...")
      {:ok, bob} = Attest.Driver.get_machine(driver, "bob")
      :ok = Attest.Machine.start(bob)
      Logger.info("bob booted")
      Logger.info("all VMs booted")

      # test execute on alice
      Logger.info("testing execute on alice...")
      {exit_code, output} = Attest.Machine.execute(alice, "hostname")
      Logger.info("alice hostname: #{String.trim(output)}")

      if exit_code != 0 do
        raise "alice execute failed"
      end

      # test execute on bob
      Logger.info("testing execute on bob...")
      {exit_code, output} = Attest.Machine.execute(bob, "hostname")
      Logger.info("bob hostname: #{String.trim(output)}")

      if exit_code != 0 do
        raise "bob execute failed"
      end

      # test parallel execution
      Logger.info("testing parallel execution...")

      task_alice =
        Task.async(fn ->
          {code, out} = Attest.Machine.execute(alice, "echo alice-says-hi && sleep 0.5")
          {code, String.trim(out)}
        end)

      task_bob =
        Task.async(fn ->
          {code, out} = Attest.Machine.execute(bob, "echo bob-says-hi && sleep 0.5")
          {code, String.trim(out)}
        end)

      {0, "alice-says-hi"} = Task.await(task_alice, 10_000)
      {0, "bob-says-hi"} = Task.await(task_bob, 10_000)
      Logger.info("parallel execution succeeded")

      # shutdown both
      Logger.info("shutting down VMs...")
      :ok = Attest.Machine.shutdown(alice, 60_000)
      Logger.info("alice shutdown complete")
      :ok = Attest.Machine.shutdown(bob, 60_000)
      Logger.info("bob shutdown complete")

      Logger.info("=== MULTI-VM TEST PASSED ===")
      :ok
    rescue
      e ->
        Logger.error("test failed: #{inspect(e)}")
        GenServer.stop(driver)
        reraise e, __STACKTRACE__
    after
      GenServer.stop(driver)
    end
  end

  defp build_machine_config(name, vm_script, state_dir) do
    qmp_path = Path.join(state_dir, "qmp")
    shell_path = Path.join(state_dir, "shell")

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

    # use TMPDIR, USE_TMPDIR, and NIX_DISK_IMAGE to isolate each VM
    disk_image = Path.join(state_dir, "nixos.qcow2")

    # use env command to set environment variables (works with Port.open spawn)
    start_command =
      "env TMPDIR=#{state_dir} USE_TMPDIR=1 NIX_DISK_IMAGE=#{disk_image} #{vm_script} #{qemu_args}"

    IO.puts(">>> Machine #{name} start_command: #{start_command}")
    IO.puts(">>> Shell socket path: #{shell_path}")

    %{
      name: name,
      start_command: start_command,
      qmp_socket_path: qmp_path,
      shell_socket_path: shell_path
    }
  end
end

MultiVMTest.run()
