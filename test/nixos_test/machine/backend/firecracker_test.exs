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

      # mock server: PUT /snapshot/load then PATCH /vm to resume
      server =
        spawn_link(fn ->
          # first request: PUT /snapshot/load
          {:ok, conn} = :gen_tcp.accept(listen, 5000)
          {:ok, data} = recv_all(conn)
          send(test_pid, {:api_call, :snapshot_load, data})
          response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"
          :gen_tcp.send(conn, response)
          :gen_tcp.close(conn)

          # second request: PATCH /vm to resume
          {:ok, conn2} = :gen_tcp.accept(listen, 5000)
          {:ok, data2} = recv_all(conn2)
          send(test_pid, {:api_call, :resume, data2})
          response2 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
          :gen_tcp.send(conn2, response2)
          :gen_tcp.close(conn2)
        end)

      config = %{name: "snap-load", state_dir: state_dir}
      {:ok, state} = Firecracker.init(config)

      assert :ok = Firecracker.snapshot_load(state, snap_dir)

      # verify snapshot load request
      assert_receive {:api_call, :snapshot_load, load_data}
      assert load_data =~ "PUT /snapshot/load"
      assert load_data =~ "snapshot_file"
      assert load_data =~ "mem_file"

      # verify resume request
      assert_receive {:api_call, :resume, resume_data}
      assert resume_data =~ "PATCH /vm"
      assert resume_data =~ "Resumed"

      Process.exit(server, :normal)
      :gen_tcp.close(listen)
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
