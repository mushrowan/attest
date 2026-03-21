defmodule Attest.Machine.Shell.Transport do
  @moduledoc """
  Behaviour for shell transport connections

  Each transport handles establishing a bidirectional connection between
  the host and the guest shell. The command protocol (base64-encoded
  output, exit codes) is transport-agnostic and stays in Shell.

  The connection type is opaque -- gen_tcp transports use a socket,
  SSH uses a bridge process pid.
  """

  @type config :: map()
  @type connection :: term()

  @doc """
  Establish a connection to the guest shell
  """
  @callback connect(config, timeout()) :: {:ok, connection} | {:error, term()}

  @doc """
  Send data over the transport
  """
  @callback send(connection, iodata()) :: :ok | {:error, term()}

  @doc """
  Receive data from the transport

  Returns any available data, blocking up to timeout milliseconds.
  """
  @callback recv(connection, timeout()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Close the transport connection and clean up resources
  """
  @callback close(connection) :: :ok
end
