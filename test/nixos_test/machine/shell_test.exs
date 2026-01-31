defmodule NixosTest.Machine.ShellTest do
  use ExUnit.Case, async: true

  alias NixosTest.Machine.Shell

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
end
