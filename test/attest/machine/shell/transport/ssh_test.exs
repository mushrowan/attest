defmodule Attest.Machine.Shell.Transport.SSHTest do
  use ExUnit.Case

  alias Attest.Machine.Shell.Transport.SSH

  setup do
    # create temp dir with host key for SSH daemon
    tmp = Path.join(System.tmp_dir!(), "ssh-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    pem = :public_key.pem_encode([entry])
    File.write!(Path.join(tmp, "ssh_host_rsa_key"), pem)
    File.chmod!(Path.join(tmp, "ssh_host_rsa_key"), 0o600)

    :ssh.start()

    exec_fn = fn command -> {:ok, command} end

    {:ok, sshd} =
      :ssh.daemon(:loopback, 0, [
        {:system_dir, String.to_charlist(tmp)},
        {:user_passwords, [{~c"testuser", ~c"testpass"}]},
        {:shell, :disabled},
        {:exec, {:direct, exec_fn}}
      ])

    {:ok, info} = :ssh.daemon_info(sshd)
    port = Keyword.fetch!(info, :port)

    on_exit(fn ->
      :ssh.stop_daemon(sshd)
      File.rm_rf!(tmp)
    end)

    %{port: port}
  end

  describe "connect/2" do
    test "connects to an SSH server with password auth", %{port: port} do
      config = %{
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass",
        mode: :exec
      }

      assert {:ok, conn} = SSH.connect(config, 5000)
      assert :ok = SSH.close(conn)
    end

    test "returns error for wrong password", %{port: port} do
      config = %{
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "wrong"
      }

      assert {:error, _} = SSH.connect(config, 5000)
    end

    test "returns error for unreachable host" do
      config = %{
        host: "127.0.0.1",
        port: 1,
        user: "testuser",
        password: "testpass",
        mode: :exec
      }

      assert {:error, _} = SSH.connect(config, 2000)
    end
  end

  describe "send/recv" do
    test "sends data and receives response", %{port: port} do
      config = %{
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass",
        mode: :exec
      }

      {:ok, conn} = SSH.connect(config, 5000)

      assert :ok = SSH.send(conn, "hello\n")
      assert {:ok, data} = SSH.recv(conn, 5000)
      assert String.contains?(data, "hello")

      SSH.close(conn)
    end

    test "recv times out when no data available", %{port: port} do
      config = %{
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass",
        mode: :exec
      }

      {:ok, conn} = SSH.connect(config, 5000)
      assert {:error, :timeout} = SSH.recv(conn, 500)
      SSH.close(conn)
    end
  end

  describe "close/1" do
    test "closes the connection cleanly", %{port: port} do
      config = %{
        host: "127.0.0.1",
        port: port,
        user: "testuser",
        password: "testpass",
        mode: :exec
      }

      {:ok, conn} = SSH.connect(config, 5000)
      assert :ok = SSH.close(conn)
    end
  end
end
