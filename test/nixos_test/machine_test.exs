defmodule NixosTest.MachineTest do
  use ExUnit.Case

  alias NixosTest.Machine
  alias NixosTest.Machine.Backend
  alias NixosTest.Machine.{QMP, Shell}

  describe "Machine" do
    test "can start a machine process" do
      {:ok, pid} = Machine.start_link(name: "test-machine", backend: Backend.Mock)
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
          backend: Backend.QEMU,
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
        end
      end)

      {:ok, machine} =
        Machine.start_link(
          name: "qmp-connect-test",
          backend: Backend.QEMU,
          qmp_socket_path: socket_path
        )

      :ok = Machine.start(machine)

      assert_receive {:qmp_received, cmd}, 2000
      assert cmd =~ "qmp_capabilities"
      assert Machine.booted?(machine)

      GenServer.stop(machine)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end

    test "start/1 retries QMP connection when socket not immediately available" do
      socket_path = Path.join(System.tmp_dir!(), "qmp-retry-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      test_pid = self()

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
          backend: Backend.QEMU,
          qmp_socket_path: socket_path
        )

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
          backend: Backend.QEMU,
          shell_socket_path: socket_path
        )

      test_pid = self()

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

      assert_receive :start_completed, 2000
      assert :ok = Task.await(task)
      assert Machine.booted?(machine)

      :gen_tcp.close(sock)
      GenServer.stop(machine)
      File.rm(socket_path)
    end
  end

  describe "execute/2" do
    test "delegates to shell and returns {exit_code, output}" do
      socket_path = Path.join(System.tmp_dir!(), "machine-test-#{:rand.uniform(10000)}.sock")
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      test_pid = self()

      spawn(fn ->
        Process.sleep(50)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")
        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("hello world\n") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")
        send(test_pid, :mock_done)
      end)

      :ok = Shell.wait_for_connection(shell, 5000)

      {:ok, machine} =
        Machine.start_link(name: "exec-test", backend: Backend.Mock, shell: shell)

      :ok = Machine.start(machine)

      assert {0, "hello world\n"} = Machine.execute(machine, "echo hello")

      assert_receive :mock_done, 1000
      GenServer.stop(machine)
      File.rm(socket_path)
    end

    test "crashes when not connected" do
      Process.flag(:trap_exit, true)

      {:ok, machine} =
        Machine.start_link(name: "not-connected-test", backend: Backend.Mock)

      catch_exit(Machine.execute(machine, "echo hello"))

      assert_receive {:EXIT, ^machine, {%RuntimeError{message: msg}, _}}, 1000
      assert msg =~ "not connected"
    end
  end

  describe "screenshot/2" do
    test "delegates to backend screenshot" do
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

        :ok =
          :gen_tcp.send(
            client,
            ~s({"QMP": {"version": {"qemu": {"major": 8}}, "capabilities": []}}\n)
          )

        {:ok, _} = :gen_tcp.recv(client, 0, 5000)
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        receive do
          :stop -> :ok
        end
      end)

      {:ok, qmp} = QMP.start_link(socket_path: socket_path)

      {:ok, machine} =
        Machine.start_link(name: "screenshot-test", backend: Backend.Mock, qmp: qmp)

      :ok = Machine.start(machine)

      assert :ok = Machine.screenshot(machine, "/tmp/test.ppm")

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
    test "sends halt via backend" do
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
        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        receive do
          :stop -> :ok
        end
      end)

      {:ok, qmp} = QMP.start_link(socket_path: socket_path)

      {:ok, machine} =
        Machine.start_link(name: "stop-test", backend: Backend.Mock, qmp: qmp)

      :ok = Machine.start(machine)

      assert :ok = Machine.stop(machine)

      # Mock.halt is a no-op, but the QMP command should not be sent
      # (Mock doesn't send quit on halt)
      # Instead, just verify the stop returns ok
      GenServer.stop(machine)
      GenServer.stop(qmp)
      :gen_tcp.close(listen)
      File.rm(socket_path)
    end
  end

  describe "wait_for_unit/3" do
    test "polls until unit is active" do
      socket_path = Path.join(System.tmp_dir!(), "shell-wait-#{:rand.uniform(10000)}.sock")
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      test_pid = self()

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

      {:ok, machine} =
        Machine.start_link(name: "wait-unit-test", backend: Backend.Mock, shell: shell)

      :ok = Machine.start(machine)

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

        {:ok, _cmd} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, Base.encode64("ActiveState=failed\n") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")
      end)

      :ok = Shell.wait_for_connection(shell, 5000)

      {:ok, machine} =
        Machine.start_link(name: "wait-fail-test", backend: Backend.Mock, shell: shell)

      :ok = Machine.start(machine)

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

      {:ok, machine} =
        Machine.start_link(name: "wait-port-test", backend: Backend.Mock, shell: shell)

      :ok = Machine.start(machine)

      assert :ok = Machine.wait_for_open_port(machine, 80, 5000)

      assert_receive :mock_done, 1000
      GenServer.stop(machine)
      File.rm(socket_path)
    end
  end

  describe "wait_for_shutdown/2" do
    test "returns :ok when process exits" do
      marker = Path.join(System.tmp_dir!(), "shutdown-marker-#{:rand.uniform(10000)}")

      {:ok, machine} =
        Machine.start_link(
          name: "wait-shutdown-test",
          backend: Backend.QEMU,
          start_command: "touch #{marker} && sleep 0.2"
        )

      :ok = Machine.start(machine)
      Process.sleep(50)
      assert File.exists?(marker)

      assert :ok = Machine.wait_for_shutdown(machine, 5000)

      GenServer.stop(machine)
      File.rm(marker)
    end

    test "returns error on timeout" do
      {:ok, machine} =
        Machine.start_link(
          name: "wait-shutdown-timeout-test",
          backend: Backend.QEMU,
          start_command: "sleep 10"
        )

      :ok = Machine.start(machine)

      assert {:error, :timeout} = Machine.wait_for_shutdown(machine, 100)

      GenServer.stop(machine)
    end
  end

  describe "halt/2" do
    test "sends halt via backend and waits for process exit" do
      socket_path = Path.join(System.tmp_dir!(), "qmp-halt-#{:rand.uniform(10000)}.sock")
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

        {:ok, cmd} = :gen_tcp.recv(client, 0, 5000)
        send(test_pid, {:qmp_command, cmd})
        :ok = :gen_tcp.send(client, ~s({"return": {}}\n))

        Process.sleep(100)
      end)

      {:ok, machine} =
        Machine.start_link(
          name: "halt-test",
          backend: Backend.QEMU,
          start_command: "sleep 0.2",
          qmp_socket_path: socket_path
        )

      :ok = Machine.start(machine)

      task = Task.async(fn -> Machine.halt(machine, 5000) end)

      assert_receive {:qmp_command, cmd}, 2000
      assert cmd =~ "quit"

      assert :ok = Task.await(task, 5000)

      :gen_tcp.close(listen)
      File.rm(socket_path)
    end
  end

  describe "shutdown/2" do
    test "sends poweroff via shell and waits for exit" do
      socket_path = Path.join(System.tmp_dir!(), "shell-shutdown-#{:rand.uniform(10000)}.sock")

      test_pid = self()

      # simulate guest connecting after shell listener starts
      spawn(fn ->
        Process.sleep(100)

        {:ok, sock} =
          :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

        :ok = :gen_tcp.send(sock, "Spawning backdoor root shell...\n")

        # receive poweroff command
        {:ok, cmd} = :gen_tcp.recv(sock, 0, 5000)
        send(test_pid, {:shell_command, cmd})

        :ok = :gen_tcp.send(sock, Base.encode64("") <> "\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5000)
        :ok = :gen_tcp.send(sock, "0\n")

        send(test_pid, :mock_done)
      end)

      {:ok, machine} =
        Machine.start_link(
          name: "shutdown-test",
          backend: Backend.QEMU,
          shell_socket_path: socket_path,
          start_command: "sleep 0.5"
        )

      :ok = Machine.start(machine)

      task = Task.async(fn -> Machine.shutdown(machine, 5000) end)

      assert_receive {:shell_command, cmd}, 2000
      assert cmd =~ "poweroff"

      assert_receive :mock_done, 1000

      assert :ok = Task.await(task, 5000)

      File.rm(socket_path)
    end
  end
end
