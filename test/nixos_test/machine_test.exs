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

    test "start/1 executes start_command" do
      marker = Path.join(System.tmp_dir!(), "machine-start-#{:rand.uniform(100_000)}")
      File.rm(marker)
      refute File.exists?(marker)

      {:ok, machine} =
        Machine.start_link(
          name: "start-cmd-test",
          start_command: "touch #{marker}"
        )

      :ok = Machine.start(machine)

      # give the command time to execute
      Process.sleep(100)
      assert File.exists?(marker)

      GenServer.stop(machine)
      File.rm(marker)
    end

    test "start/1 connects to QMP socket" do
      socket_path = Path.join(System.tmp_dir!(), "qmp-start-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      # start mock QMP server first (simulating QEMU creating the socket)
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:packet, :line},
          {:active, false},
          {:ip, {:local, socket_path}}
        ])

      test_pid = self()

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen, 5000)
        # send QMP greeting
        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        # receive qmp_capabilities, send ok
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_received, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        # keep connection open
        receive do
          :stop -> :ok
        end
      end)

      {:ok, machine} =
        Machine.start_link(
          name: "qmp-connect-test",
          qmp_socket_path: socket_path
        )

      :ok = Machine.start(machine)

      # verify QMP negotiation happened
      assert_receive {:qmp_received, cmd}, 2000
      assert cmd =~ "qmp_capabilities"

      # machine should now have QMP connected
      assert Machine.booted?(machine)

      GenServer.stop(machine)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end

    test "start/1 retries QMP connection when socket not immediately available" do
      socket_path = Path.join(System.tmp_dir!(), "qmp-retry-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      test_pid = self()

      # delay socket creation by 200ms (simulating QEMU startup)
      spawn(fn ->
        Process.sleep(200)

        {:ok, listen} =
          :gen_tcp.listen(0, [
            :binary,
            {:packet, :line},
            {:active, false},
            {:ip, {:local, socket_path}}
          ])

        {:ok, client} = :gen_tcp.accept(listen, 5000)

        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_received, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        receive do
          :stop -> :ok
        after
          10_000 -> :ok
        end

        :gen_tcp.close(listen)
      end)

      {:ok, machine} =
        Machine.start_link(
          name: "qmp-retry-test",
          qmp_socket_path: socket_path
        )

      # should succeed despite socket not existing initially
      :ok = Machine.start(machine)

      assert_receive {:qmp_received, cmd}, 3000
      assert cmd =~ "qmp_capabilities"
      assert Machine.booted?(machine)

      GenServer.stop(machine)
      File.rm(socket_path)
    end

    test "start/1 waits for shell connection" do
      socket_path = Path.join(System.tmp_dir!(), "shell-start-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      {:ok, machine} =
        Machine.start_link(
          name: "shell-connect-test",
          shell_socket_path: socket_path
        )

      test_pid = self()

      # start Machine.start in a task (it will block waiting for connection)
      task =
        Task.async(fn ->
          result = Machine.start(machine)
          send(test_pid, :start_completed)
          result
        end)

      # give shell time to start listening
      Process.sleep(50)

      # simulate guest connecting
      {:ok, sock} =
        :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

      :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")

      # start should complete now
      assert_receive :start_completed, 2000
      assert :ok = Task.await(task)

      # machine should be connected
      assert Machine.booted?(machine)

      :gen_tcp.close(sock)
      GenServer.stop(machine)
      File.rm(socket_path)
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

  describe "screenshot/2" do
    test "delegates to QMP screendump command" do
      # set up mock QMP server
      socket_path = Path.join(System.tmp_dir!(), "qmp-test-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:packet, :line},
          {:active, false},
          {:ip, {:local, socket_path}}
        ])

      test_pid = self()

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)
        # send greeting
        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        # receive qmp_capabilities, send ok
        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))
        # receive screendump command
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        receive do
          :stop -> :ok
        end
      end)

      {:ok, qmp} = QMP.start_link(socket_path: socket_path)
      {:ok, machine} = Machine.start_link(name: "screenshot-test", qmp: qmp)

      assert :ok = Machine.screenshot(machine, "/tmp/test.ppm")

      # verify the command sent
      assert_receive {:qmp_command, cmd}, 1000
      assert cmd =~ "screendump"
      assert cmd =~ "/tmp/test.ppm"

      GenServer.stop(machine)
      GenServer.stop(qmp)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end
  end

  describe "stop/1" do
    test "sends QMP quit command" do
      socket_path = Path.join(System.tmp_dir!(), "qmp-stop-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:packet, :line},
          {:active, false},
          {:ip, {:local, socket_path}}
        ])

      test_pid = self()

      spawn(fn ->
        {:ok, client} = :gen_tcp.accept(listen)

        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))
        # receive quit command
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        receive do
          :stop -> :ok
        end
      end)

      {:ok, qmp} = QMP.start_link(socket_path: socket_path)
      {:ok, machine} = Machine.start_link(name: "stop-test", qmp: qmp)

      assert :ok = Machine.stop(machine)

      assert_receive {:qmp_command, cmd}, 1000
      assert cmd =~ "quit"

      GenServer.stop(machine)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end
  end

  describe "wait_for_unit/3" do
    test "polls until unit is active" do
      socket_path = Path.join(System.tmp_dir!(), "shell-wait-#{:rand.uniform(10000)}.sock")
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      test_pid = self()

      # mock guest that returns "activating" then "active"
      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")

        # first poll - activating
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("ActiveState=activating\n") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")

        # second poll - active
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("ActiveState=active\n") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")

        send(test_pid, :mock_done)
      end)

      :ok = Shell.wait_for_connection(shell, 5000)
      {:ok, machine} = Machine.start_link(name: "wait-unit-test", shell: shell)

      assert :ok = Machine.wait_for_unit(machine, "nginx.service", 5000)

      assert_receive :mock_done, 1000
      GenServer.stop(machine)
      File.rm(socket_path)
    end

    test "raises on failed unit" do
      socket_path = Path.join(System.tmp_dir!(), "shell-fail-#{:rand.uniform(10000)}.sock")
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")

        # return failed state
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("ActiveState=failed\n") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")
      end)

      :ok = Shell.wait_for_connection(shell, 5000)
      {:ok, machine} = Machine.start_link(name: "wait-fail-test", shell: shell)

      Process.flag(:trap_exit, true)
      catch_exit(Machine.wait_for_unit(machine, "bad.service", 5000))

      assert_receive {:EXIT, ^machine, {%RuntimeError{message: msg}, _}}, 1000
      assert msg =~ "failed"

      File.rm(socket_path)
    end
  end

  describe "wait_for_open_port/3" do
    test "polls until port is open" do
      socket_path = Path.join(System.tmp_dir!(), "shell-port-#{:rand.uniform(10000)}.sock")
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      test_pid = self()

      # mock guest: first nc fails, second succeeds
      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")

        # first poll - port closed (non-zero exit)
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "1\n")

        # second poll - port open (zero exit)
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")

        send(test_pid, :mock_done)
      end)

      :ok = Shell.wait_for_connection(shell, 5000)
      {:ok, machine} = Machine.start_link(name: "wait-port-test", shell: shell)

      assert :ok = Machine.wait_for_open_port(machine, 80, 5000)

      assert_receive :mock_done, 1000
      GenServer.stop(machine)
      File.rm(socket_path)
    end
  end
end
