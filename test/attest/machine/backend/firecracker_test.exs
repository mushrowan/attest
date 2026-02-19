defmodule Attest.Machine.Backend.FirecrackerTest do
  use ExUnit.Case

  alias Attest.Machine.Backend.Firecracker

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

    test "defaults huge_pages to nil" do
      config = %{
        name: "hp-default",
        firecracker_bin: "/usr/bin/firecracker",
        kernel_image_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4"
      }

      assert {:ok, state} = Firecracker.init(config)
      assert state.huge_pages == nil
    end

    test "stores huge_pages when set" do
      config = %{
        name: "hp-enabled",
        firecracker_bin: "/usr/bin/firecracker",
        kernel_image_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4",
        huge_pages: "2M"
      }

      assert {:ok, state} = Firecracker.init(config)
      assert state.huge_pages == "2M"
    end

    test "stores entropy when set" do
      config = %{
        name: "ent-enabled",
        firecracker_bin: "/usr/bin/firecracker",
        kernel_image_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.ext4",
        entropy: true
      }

      assert {:ok, state} = Firecracker.init(config)
      assert state.entropy == true
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

  describe "snapshot_create/2" do
    test "pauses VM and creates snapshot via API" do
      # mock HTTP server on unix socket to verify API calls
      state_dir = Path.join(System.tmp_dir!(), "fc-snap-create-#{:rand.uniform(100_000)}")
      snap_dir = Path.join(state_dir, "snapshots")
      File.mkdir_p!(state_dir)
      api_socket = Path.join(state_dir, "firecracker.sock")
      File.rm(api_socket)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:active, false},
          {:ip, {:local, api_socket}}
        ])

      test_pid = self()

      # spawn mock API server that expects PATCH /vm then PUT /snapshot/create
      server =
        spawn_link(fn ->
          # first request: PATCH /vm to pause
          {:ok, conn} = :gen_tcp.accept(listen, 5000)
          {:ok, data} = recv_all(conn)
          send(test_pid, {:api_call, :pause, data})
          response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
          :gen_tcp.send(conn, response)
          :gen_tcp.close(conn)

          # second request: PUT /snapshot/create
          {:ok, conn2} = :gen_tcp.accept(listen, 5000)
          {:ok, data2} = recv_all(conn2)
          send(test_pid, {:api_call, :snapshot_create, data2})
          response2 = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
          :gen_tcp.send(conn2, response2)
          :gen_tcp.close(conn2)
        end)

      config = %{name: "snap-create", state_dir: state_dir}
      {:ok, state} = Firecracker.init(config)

      assert :ok = Firecracker.snapshot_create(state, snap_dir)

      # verify pause request
      assert_receive {:api_call, :pause, pause_data}
      assert pause_data =~ "PATCH /vm"
      assert pause_data =~ "Paused"

      # verify snapshot create request
      assert_receive {:api_call, :snapshot_create, snap_data}
      assert snap_data =~ "PUT /snapshot/create"
      assert snap_data =~ "snapshot_file"
      assert snap_data =~ "mem_file"

      Process.exit(server, :normal)
      :gen_tcp.close(listen)
      File.rm_rf!(state_dir)
    end
  end

  describe "snapshot_load/2" do
    test "loads snapshot and resumes VM via API" do
      state_dir = Path.join(System.tmp_dir!(), "fc-snap-load-#{:rand.uniform(100_000)}")
      snap_dir = Path.join(state_dir, "snapshots")
      File.mkdir_p!(state_dir)
      api_socket = Path.join(state_dir, "firecracker.sock")
      File.rm(api_socket)

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:active, false},
          {:ip, {:local, api_socket}}
        ])

      test_pid = self()

      # mock server: PUT /snapshot/load with resume_vm=true
      server =
        spawn_link(fn ->
          {:ok, conn} = :gen_tcp.accept(listen, 5000)
          {:ok, data} = recv_all(conn)
          send(test_pid, {:api_call, :snapshot_load, data})
          response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
          :gen_tcp.send(conn, response)
          :gen_tcp.close(conn)
        end)

      config = %{name: "snap-load", state_dir: state_dir}
      {:ok, state} = Firecracker.init(config)

      assert :ok = Firecracker.snapshot_load(state, snap_dir)

      # verify snapshot load request includes resume_vm
      assert_receive {:api_call, :snapshot_load, load_data}
      assert load_data =~ "PUT /snapshot/load"
      assert load_data =~ "snapshot_file"
      assert load_data =~ "mem_file"
      assert load_data =~ "resume_vm"

      Process.exit(server, :normal)
      :gen_tcp.close(listen)
      File.rm_rf!(state_dir)
    end
  end

  describe "restore_from_snapshot/2" do
    @tag timeout: 15_000
    test "spawns new FC process, loads snapshot, resumes, reconnects shell" do
      state_dir = Path.join(System.tmp_dir!(), "fc-restore-#{:rand.uniform(100_000)}")
      snap_dir = Path.join(state_dir, "snapshots")
      File.mkdir_p!(snap_dir)

      api_socket = Path.join(state_dir, "firecracker.sock")
      vsock_uds = Path.join(state_dir, "v.sock")
      File.rm(api_socket)
      File.rm(vsock_uds)

      test_pid = self()

      # mock FC binary: traps TERM and exits cleanly
      mock_bin = Path.join(state_dir, "mock-fc")

      File.write!(mock_bin, """
      #!/bin/sh
      trap 'exit 0' TERM
      while true; do sleep 0.1; done
      """)

      File.chmod!(mock_bin, 0o755)

      config = %{
        name: "restore-test",
        firecracker_bin: mock_bin,
        kernel_image_path: "/dev/null",
        rootfs_path: "/dev/null",
        state_dir: state_dir,
        vsock_port: 1234
      }

      {:ok, state} = Firecracker.init(config)

      # simulate having a running FC process (old instance)
      old_port = Port.open({:spawn, "sleep 10"}, [:binary, :exit_status])
      state = %{state | fc_port: old_port, port_exited: false}

      # spawn mock API + vsock server for the NEW firecracker instance
      mock_server =
        spawn(fn ->
          # wait for old process cleanup and new FC binary to spawn
          Process.sleep(200)

          # create API socket
          {:ok, api_listen} =
            :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {:local, api_socket}}])

          # handle PUT /snapshot/load (with resume_vm=true)
          {:ok, conn1} = :gen_tcp.accept(api_listen, 10_000)
          {:ok, data1} = recv_all(conn1)
          send(test_pid, {:restore_api, :load, data1})
          :gen_tcp.send(conn1, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
          :gen_tcp.close(conn1)

          # create vsock UDS and handle shell CONNECT protocol
          {:ok, vsock_listen} =
            :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {:local, vsock_uds}}])

          {:ok, vsock_conn} = :gen_tcp.accept(vsock_listen, 10_000)
          {:ok, _connect} = :gen_tcp.recv(vsock_conn, 0, 5_000)
          :gen_tcp.send(vsock_conn, "OK 1234\n")
          :gen_tcp.send(vsock_conn, "Spawning backdoor root shell...\n")
          :inet.setopts(vsock_conn, [{:packet, :line}])
          {:ok, _cmd} = :gen_tcp.recv(vsock_conn, 0, 30_000)
          :gen_tcp.send(vsock_conn, Base.encode64("restored-ok") <> "\n")
          {:ok, _} = :gen_tcp.recv(vsock_conn, 0, 30_000)
          :gen_tcp.send(vsock_conn, "0\n")

          receive do
            :stop -> :ok
          after
            30_000 -> :ok
          end
        end)

      # call restore_from_snapshot
      assert {:ok, shell_pid, new_state} =
               Firecracker.restore_from_snapshot(state, snap_dir)

      assert is_pid(shell_pid)
      assert new_state.shell == shell_pid
      assert new_state.fc_port != old_port

      # verify the API calls were made (resume_vm=true, single call)
      assert_receive {:restore_api, :load, load_data}, 5000
      assert load_data =~ "PUT /snapshot/load"
      assert load_data =~ "resume_vm"

      # verify shell works after restore
      assert {:ok, "restored-ok", 0} =
               Attest.Machine.Shell.execute(shell_pid, "echo test")

      # cleanup
      send(mock_server, :stop)

      if Process.alive?(shell_pid), do: GenServer.stop(shell_pid)

      # kill the mock FC process via SIGTERM (it traps and exits)
      if new_state.fc_port do
        try do
          Port.close(new_state.fc_port)
        rescue
          _ -> :ok
        end

        # drain the exit_status message
        receive do
          {_, {:exit_status, _}} -> :ok
        after
          1000 -> :ok
        end
      end

      File.rm_rf!(state_dir)
    end
  end

  defp recv_all(socket) do
    recv_all(socket, "")
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 500) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :timeout} -> {:ok, acc}
      {:error, :closed} -> {:ok, acc}
    end
  end
end
