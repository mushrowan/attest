defmodule NixosTest.MachineTest do
  use ExUnit.Case

  alias NixosTest.Machine
  alias NixosTest.Machine.{QMP, Shell}

  describe "Machine" do
    test "can start a machine process" do
      {:ok, pid} = Machine.start_link(name: "test-machine")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "execute/2" do
    test "delegates to shell and returns {exit_code, output}" do
      # set up mock shell
      socket_path = Path.join(System.tmp_dir!(), "machine-test-#{:rand.uniform(10000)}.sock")
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      # spawn mock guest
      test_pid = self()

      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")
        # receive command, send response
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("hello world\n") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")
        send(test_pid, :mock_done)
      end)

      :ok = Shell.wait_for_connection(shell, 5000)

      # start machine with injected shell
      {:ok, machine} = Machine.start_link(name: "exec-test", shell: shell)

      # execute should delegate to shell
      assert {0, "hello world\n"} = Machine.execute(machine, "echo hello")

      assert_receive :mock_done, 1000
      GenServer.stop(machine)
      File.rm(socket_path)
    end

    test "crashes when not connected" do
      Process.flag(:trap_exit, true)
      {:ok, machine} = Machine.start_link(name: "not-connected-test")

      # raising in GenServer handle_call causes exit, not raise
      catch_exit(Machine.execute(machine, "echo hello"))

      # should receive EXIT from the crashed GenServer
      assert_receive {:EXIT, ^machine, {%RuntimeError{message: msg}, _}}, 1000
      assert msg =~ "not connected"
    end
  end
end
