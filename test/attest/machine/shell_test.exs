defmodule Attest.Machine.ShellTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.Shell

  # helper to simulate QEMU connecting to shell socket
  defp with_mock_guest(socket_path, fun) do
    # connect as if we're the guest
    # small delay to let server start listening
    Process.sleep(50)

    {:ok, socket} =
      :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])

    # send the backdoor ready message
    :ok = :gen_tcp.send(socket, "Spawning backdoor root shell...\n")

    fun.(socket)
    :gen_tcp.close(socket)
  end

  describe "format_command/1" do
    test "wraps command in bash with base64 encoding" do
      cmd = Shell.format_command("echo hello")
      assert cmd =~ "bash -c"
      assert cmd =~ "echo hello"
      assert cmd =~ "base64"
      assert String.ends_with?(cmd, "\n")
    end

    test "properly escapes single quotes" do
      cmd = Shell.format_command("echo 'hello'")
      # single quotes inside are escaped as '\''
      assert cmd =~ "echo '\\''hello'\\''"
    end
  end

  describe "parse_output/2" do
    test "decodes base64 output and exit code" do
      # "hello\n" in base64
      base64_output = "aGVsbG8K"
      exit_code = "0"

      assert {:ok, "hello\n", 0} = Shell.parse_output(base64_output, exit_code)
    end

    test "handles empty output" do
      assert {:ok, "", 0} = Shell.parse_output("", "0")
    end

    test "handles non-zero exit code" do
      base64_output = Base.encode64("error message")
      assert {:ok, "error message", 1} = Shell.parse_output(base64_output, "1")
    end

    test "handles whitespace in exit code" do
      base64_output = Base.encode64("ok")
      assert {:ok, "ok", 0} = Shell.parse_output(base64_output, "  0  \n")
    end
  end

  describe "execute/2" do
    test "executes command and returns output" do
      # use short socket path to avoid unix socket path limit
      socket_path = Path.join(System.tmp_dir!(), "sh-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      # start shell server
      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      # spawn mock guest that will respond to commands
      test_pid = self()

      spawn(fn ->
        with_mock_guest(socket_path, fn socket ->
          # receive command
          {:ok, _cmd} = :gen_tcp.recv(socket, 0, 5000)
          # send base64 encoded output
          :ok = :gen_tcp.send(socket, Base.encode64("hello world\n") <> "\n")
          # receive exit code request
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
          # send exit code
          :ok = :gen_tcp.send(socket, "0\n")
          send(test_pid, :mock_done)
        end)
      end)

      # wait for connection
      :ok = Shell.wait_for_connection(shell, 5000)

      # execute command
      assert {:ok, "hello world\n", 0} = Shell.execute(shell, "echo hello world")

      assert_receive :mock_done, 1000
      GenServer.stop(shell)
      File.rm(socket_path)
    end

    test "returns non-zero exit code on failure" do
      socket_path = Path.join(System.tmp_dir!(), "sh-#{:rand.uniform(10000)}.sock")
      File.rm(socket_path)

      {:ok, shell} = Shell.start_link(socket_path: socket_path)

      test_pid = self()

      spawn(fn ->
        with_mock_guest(socket_path, fn socket ->
          {:ok, _cmd} = :gen_tcp.recv(socket, 0, 5000)
          :ok = :gen_tcp.send(socket, Base.encode64("command not found\n") <> "\n")
          {:ok, _} = :gen_tcp.recv(socket, 0, 5000)
          :ok = :gen_tcp.send(socket, "127\n")
          send(test_pid, :mock_done)
        end)
      end)

      :ok = Shell.wait_for_connection(shell, 5000)

      assert {:ok, "command not found\n", 127} = Shell.execute(shell, "nonexistent")

      assert_receive :mock_done, 1000
      GenServer.stop(shell)
      File.rm(socket_path)
    end
  end
end
