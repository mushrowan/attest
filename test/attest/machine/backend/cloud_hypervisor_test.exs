defmodule Attest.Machine.Backend.CloudHypervisorTest do
  use ExUnit.Case

  alias Attest.Machine.Backend.CloudHypervisor

  describe "init/1" do
    test "stores config and derives socket paths" do
      config = %{
        name: "test-ch",
        cloud_hypervisor_bin: "/usr/bin/cloud-hypervisor",
        kernel_image_path: "/path/to/vmlinux",
        rootfs_path: "/path/to/rootfs.raw",
        state_dir: "/tmp/ch-test"
      }

      assert {:ok, state} = CloudHypervisor.init(config)
      assert state.name == "test-ch"
      assert state.api_socket_path == "/tmp/ch-test/cloud-hypervisor.sock"
      assert state.vsock_uds_path == "/tmp/ch-test/v.sock"
    end

    test "uses defaults for optional fields" do
      config = %{name: "defaults", state_dir: "/tmp/ch-defaults"}
      {:ok, state} = CloudHypervisor.init(config)
      assert state.vcpu_count == 1
      assert state.mem_size_mib == 256
      assert state.vsock_cid == 3
      assert state.vsock_port == 1234
    end
  end

  describe "capabilities/1" do
    test "returns empty list (no VGA or keyboard)" do
      {:ok, state} = CloudHypervisor.init(%{name: "cap", state_dir: "/tmp/ch-cap"})
      assert CloudHypervisor.capabilities(state) == []
    end
  end

  describe "unsupported operations" do
    setup do
      {:ok, state} = CloudHypervisor.init(%{name: "unsup", state_dir: "/tmp/ch-unsup"})
      %{state: state}
    end

    test "screenshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.screenshot(state, "test.ppm")
    end

    test "send_key returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.send_key(state, "ret")
    end

    test "forward_port returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.forward_port(state, 8080, 80)
    end

    test "send_console returns unsupported", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.send_console(state, "hi")
    end

    test "snapshot_load returns unsupported (use restore_from_snapshot)", %{state: state} do
      assert {:error, :unsupported} = CloudHypervisor.snapshot_load(state, "/tmp")
    end
  end

  describe "handle_port_exit/2" do
    test "marks port as exited" do
      {:ok, state} = CloudHypervisor.init(%{name: "exit", state_dir: "/tmp/ch-exit"})
      new_state = CloudHypervisor.handle_port_exit(state, 0)
      assert new_state.port_exited == true
      assert new_state.ch_port == nil
    end
  end

  describe "build_vm_config/1" do
    test "produces valid cloud-hypervisor VmConfig JSON" do
      {:ok, state} =
        CloudHypervisor.init(%{
          name: "cfg-test",
          kernel_image_path: "/vmlinux",
          rootfs_path: "/rootfs.ext4",
          initrd_path: "/initrd",
          kernel_boot_args: "console=ttyS0",
          vcpu_count: 2,
          mem_size_mib: 512,
          state_dir: "/tmp/ch-cfg"
        })

      config = CloudHypervisor.build_vm_config(state)

      assert config["payload"]["kernel"] == "/vmlinux"
      assert config["payload"]["initramfs"] == "/initrd"
      assert config["payload"]["cmdline"] == "console=ttyS0"
      assert config["cpus"]["boot_vcpus"] == 2
      assert config["memory"]["size"] == 512 * 1024 * 1024
      assert hd(config["disks"])["path"] == "/rootfs.ext4"
      assert config["serial"]["mode"] == "Null"
    end

    test "includes vsock config" do
      {:ok, state} =
        CloudHypervisor.init(%{
          name: "vsock-cfg",
          kernel_image_path: "/vmlinux",
          state_dir: "/tmp/ch-vsock-cfg"
        })

      config = CloudHypervisor.build_vm_config(state)

      assert config["vsock"]["cid"] == 3
      assert config["vsock"]["socket"] == "/tmp/ch-vsock-cfg/v.sock"
    end

    test "omits initramfs when nil" do
      {:ok, state} =
        CloudHypervisor.init(%{
          name: "no-initrd",
          kernel_image_path: "/vmlinux",
          state_dir: "/tmp/ch-no-initrd"
        })

      config = CloudHypervisor.build_vm_config(state)
      refute Map.has_key?(config["payload"], "initramfs")
    end
  end

  describe "snapshot_create/2" do
    test "pauses VM and creates snapshot via API" do
      state_dir = Path.join(System.tmp_dir!(), "ch-snap-create-#{:rand.uniform(100_000)}")
      snap_dir = Path.join(state_dir, "snapshots")
      File.mkdir_p!(state_dir)
      api_socket = Path.join(state_dir, "cloud-hypervisor.sock")
      File.rm(api_socket)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {:local, api_socket}}])

      test_pid = self()

      server =
        spawn_link(fn ->
          # first: PUT /api/v1/vm.pause
          {:ok, conn} = :gen_tcp.accept(listen, 5000)
          {:ok, data} = recv_all(conn)
          send(test_pid, {:api_call, :pause, data})
          :gen_tcp.send(conn, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
          :gen_tcp.close(conn)

          # second: PUT /api/v1/vm.snapshot
          {:ok, conn2} = :gen_tcp.accept(listen, 5000)
          {:ok, data2} = recv_all(conn2)
          send(test_pid, {:api_call, :snapshot, data2})
          :gen_tcp.send(conn2, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
          :gen_tcp.close(conn2)
        end)

      config = %{name: "snap-create", state_dir: state_dir}
      {:ok, state} = CloudHypervisor.init(config)

      assert :ok = CloudHypervisor.snapshot_create(state, snap_dir)

      assert_receive {:api_call, :pause, pause_data}
      assert pause_data =~ "PUT /api/v1/vm.pause"

      assert_receive {:api_call, :snapshot, snap_data}
      assert snap_data =~ "PUT /api/v1/vm.snapshot"
      assert snap_data =~ "file://#{snap_dir}"

      Process.exit(server, :normal)
      :gen_tcp.close(listen)
      File.rm_rf!(state_dir)
    end
  end

  describe "restore_from_snapshot/2" do
    @tag timeout: 15_000
    test "spawns new CH, restores snapshot, resumes, reconnects shell" do
      state_dir = Path.join(System.tmp_dir!(), "ch-restore-#{:rand.uniform(100_000)}")
      snap_dir = Path.join(state_dir, "snapshots")
      File.mkdir_p!(snap_dir)

      api_socket = Path.join(state_dir, "cloud-hypervisor.sock")
      vsock_uds = Path.join(state_dir, "v.sock")
      File.rm(api_socket)
      File.rm(vsock_uds)

      test_pid = self()

      mock_bin = Path.join(state_dir, "mock-ch")

      File.write!(mock_bin, """
      #!/bin/sh
      trap 'exit 0' TERM
      while true; do sleep 0.1; done
      """)

      File.chmod!(mock_bin, 0o755)

      config = %{
        name: "restore-test",
        cloud_hypervisor_bin: mock_bin,
        kernel_image_path: "/dev/null",
        rootfs_path: "/dev/null",
        state_dir: state_dir,
        vsock_port: 1234
      }

      {:ok, state} = CloudHypervisor.init(config)

      old_port = Port.open({:spawn, "sleep 10"}, [:binary, :exit_status])
      state = %{state | ch_port: old_port, port_exited: false}

      mock_server =
        spawn(fn ->
          Process.sleep(200)

          {:ok, api_listen} =
            :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {:local, api_socket}}])

          # PUT /api/v1/vm.restore
          {:ok, conn1} = :gen_tcp.accept(api_listen, 10_000)
          {:ok, data1} = recv_all(conn1)
          send(test_pid, {:restore_api, :restore, data1})
          :gen_tcp.send(conn1, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
          :gen_tcp.close(conn1)

          # PUT /api/v1/vm.resume
          {:ok, conn2} = :gen_tcp.accept(api_listen, 10_000)
          {:ok, data2} = recv_all(conn2)
          send(test_pid, {:restore_api, :resume, data2})
          :gen_tcp.send(conn2, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
          :gen_tcp.close(conn2)

          # vsock shell
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

      assert {:ok, shell_pid, new_state} =
               CloudHypervisor.restore_from_snapshot(state, snap_dir)

      assert is_pid(shell_pid)
      assert new_state.shell == shell_pid
      assert new_state.ch_port != old_port

      assert_receive {:restore_api, :restore, restore_data}, 5000
      assert restore_data =~ "PUT /api/v1/vm.restore"
      assert restore_data =~ "file://#{snap_dir}"

      assert_receive {:restore_api, :resume, resume_data}, 5000
      assert resume_data =~ "PUT /api/v1/vm.resume"

      assert {:ok, "restored-ok", 0} =
               Attest.Machine.Shell.execute(shell_pid, "echo test")

      send(mock_server, :stop)
      if Process.alive?(shell_pid), do: GenServer.stop(shell_pid)

      if new_state.ch_port do
        try do
          Port.close(new_state.ch_port)
        rescue
          _ -> :ok
        end

        receive do
          {_, {:exit_status, _}} -> :ok
        after
          1000 -> :ok
        end
      end

      File.rm_rf!(state_dir)
    end
  end

  defp recv_all(socket), do: recv_all(socket, "")

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 500) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :timeout} -> {:ok, acc}
      {:error, :closed} -> {:ok, acc}
    end
  end
end
