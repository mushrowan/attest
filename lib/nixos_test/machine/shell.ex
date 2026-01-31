defmodule NixosTest.Machine.Shell do
  @moduledoc """
  Shell backdoor client for executing commands inside a QEMU guest.

  The shell uses the virtconsole device to communicate with a shell running
  inside the guest VM. Commands are sent over this channel and outputs are
  base64-encoded to handle binary data safely.

  ## Protocol

  1. Send: `bash -c '<command>' | (base64 -w 0; echo)\n`
  2. Recv: `<base64 encoded output>\n`
  3. Send: `echo ${PIPESTATUS[0]}\n`
  4. Recv: `<exit code>\n`
  """

  @doc """
  Format a command for execution over the shell backdoor.

  Wraps the command in bash with base64 encoding of output.
  """
  @spec format_command(String.t()) :: String.t()
  def format_command(command) do
    # use single quotes and escape any single quotes in the command
    escaped = String.replace(command, "'", "'\\''")
    "bash -c '#{escaped}' | (base64 -w 0; echo)\n"
  end

  @doc """
  Parse the output from a shell command execution.

  Takes the base64-encoded output and exit code string,
  returns `{:ok, output, exit_code}`.
  """
  @spec parse_output(String.t(), String.t()) :: {:ok, String.t(), non_neg_integer()}
  def parse_output(base64_output, exit_code_str) do
    output =
      case Base.decode64(base64_output) do
        {:ok, decoded} -> decoded
        :error -> ""
      end

    exit_code =
      exit_code_str
      |> String.trim()
      |> String.to_integer()

    {:ok, output, exit_code}
  end
end
