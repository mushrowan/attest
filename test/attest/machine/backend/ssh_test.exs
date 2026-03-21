defmodule Attest.Machine.Backend.SSHTest do
  use ExUnit.Case

  alias Attest.Machine.Backend.SSH

  setup do
    # create temp dir with host key for SSH daemon
    tmp = Path.join(System.tmp_dir!(), "ssh-backend-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp)

    key = :public_key.generate_key({:rsa, 2048, 65537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([entry])
    File.write!(Path.join(tmp, "ssh_host_rsa_key"), pem)
    File.chmod!(Path.join(tmp, "ssh_host_rsa_key"), 0o600)

    # echo shell for the test SSH daemon
    shell_fn = fn _user ->
      spawn(fn -> ssh_echo_loop() end)
    end

    {:ok, sshd} =
      :ssh.daemon(:loopback, 0, [
        {:system_dir, String.to_charlist(tmp)},
        {:user_passwords, [{~c"testuser", ~c"testpass"}]},
        {:shell, shell_fn}
      ])

    {:ok, info} = :ssh.daemon_info(sshd)
    port = Keyword.fetch!(info, :port)

    on_exit(fn ->
      :ssh.stop_daemon(sshd)
      File.rm_rf!(tmp)
    end)

    %{port: port}
  end

  describe "init/1" do
    test "stores config" do
      config = %{
        name: "remote-box",
        host: "10.0.0.1",
        port: 2222,
        user: "admin",
        password: "secret"
      }

      assert {:ok, state} = SSH.init(config)
      assert state.name == "remote-box"
      assert state.host == "10.0.0.1"
      assert state.port == 2222
      assert state.user == "admin"
      assert state.password == "secret"
    end

    test "uses defaults for optional fields" do
      config = %{host: "10.0.0.1"}
      {:ok, state} = SSH.init(config)
      assert state.name == "unknown"
      assert state.port == 22
      assert state.user == "root"
    end
  end

  describe "capabilities/1" do
    test "returns empty list" do
      {:ok, state} = SSH.init(%{host: "10.0.0.1"})
      assert SSH.capabilities(state) == []
    end
  end

  describe "unsupported operations" do
    setup do
      {:ok, state} = SSH.init(%{host: "10.0.0.1"})
      %{state: state}
    end

    test "screenshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.screenshot(state, "test.ppm")
    end

    test "send_key returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.send_key(state, "ret")
    end

    test "forward_port returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.forward_port(state, 8080, 80)
    end

    test "send_console returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.send_console(state, "hi")
    end

    test "block returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.block(state)
    end

    test "unblock returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.unblock(state)
    end

    test "snapshot_create returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.snapshot_create(state, "/tmp")
    end

    test "snapshot_load returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.snapshot_load(state, "/tmp")
    end

    test "restore_from_snapshot returns unsupported", %{state: state} do
      assert {:error, :unsupported} = SSH.restore_from_snapshot(state, "/tmp")
    end
  end

  describe "start/1" do
    test "connects via SSH and returns shell pid", %{port: port} do
      config = %{
        name: "ssh-start",
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass"
      }

      {:ok, state} = SSH.init(config)
      assert {:ok, shell_pid, new_state} = SSH.start(state)
      assert is_pid(shell_pid)
      assert new_state.shell == shell_pid
      assert new_state.connected == true

      SSH.cleanup(new_state)
    end

    test "returns error for unreachable host" do
      config = %{
        name: "ssh-fail",
        host: "127.0.0.1",
        port: 1,
        user: "testuser",
        password: "testpass"
      }

      {:ok, state} = SSH.init(config)
      assert {:error, _} = SSH.start(state)
    end
  end

  describe "shutdown/2" do
    test "sends shutdown command and cleans up", %{port: port} do
      config = %{
        name: "ssh-shutdown",
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass"
      }

      {:ok, state} = SSH.init(config)
      {:ok, shell, state} = SSH.start(state)
      assert Process.alive?(shell)

      assert :ok = SSH.shutdown(state, 5000)
      Process.sleep(100)
      refute Process.alive?(shell)
    end
  end

  describe "halt/2" do
    test "closes connection immediately", %{port: port} do
      config = %{
        name: "ssh-halt",
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass"
      }

      {:ok, state} = SSH.init(config)
      {:ok, shell, state} = SSH.start(state)
      assert Process.alive?(shell)

      assert :ok = SSH.halt(state, 5000)
      Process.sleep(100)
      refute Process.alive?(shell)
    end
  end

  describe "cleanup/1" do
    test "stops shell process", %{port: port} do
      config = %{
        name: "ssh-cleanup",
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass"
      }

      {:ok, state} = SSH.init(config)
      {:ok, shell, state} = SSH.start(state)
      assert Process.alive?(shell)

      assert :ok = SSH.cleanup(state)
      Process.sleep(100)
      refute Process.alive?(shell)
    end
  end

  describe "handle_port_exit/2" do
    test "returns state unchanged" do
      {:ok, state} = SSH.init(%{host: "10.0.0.1"})
      assert ^state = SSH.handle_port_exit(state, 0)
    end
  end

  defp ssh_echo_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data ->
        IO.write(:stdio, data)
        ssh_echo_loop()
    end
  end
end
