defmodule Attest.Machine.Shell.Transport do
  @moduledoc """
  Behaviour for shell transport connections

  Each transport handles establishing a bidirectional connection between
  the host and the guest shell. The command protocol (base64-encoded
  output, exit codes) is transport-agnostic and stays in Shell.
  """

  @type config :: map()

  @doc """
  Establish a connection to the guest shell

  Returns a connected `:gen_tcp.socket()` ready for the shell command protocol.
  """
  @callback connect(config, timeout()) :: {:ok, :gen_tcp.socket()} | {:error, term()}

  @doc """
  Close the transport connection and clean up resources
  """
  @callback close(:gen_tcp.socket()) :: :ok
end
