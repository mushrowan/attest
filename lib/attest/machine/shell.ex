defmodule Attest.Machine.Shell do
  @moduledoc """
  Shell client for executing commands inside a guest VM

  Uses a pluggable transport to establish a connection, then communicates
  using a base64-encoded command protocol:

  1. Send: `bash -c '<command>' | (base64 -w 0; echo)\n`
  2. Recv: `<base64 encoded output>\n`
  3. Send: `echo ${PIPESTATUS[0]}\n`
  4. Recv: `<exit code>\n`

  Transports: VirtConsole (QEMU), Vsock (firecracker/cloud-hypervisor),
  SSH (remote hosts).
  """

  use GenServer
  require Logger

  alias Attest.Machine.Shell.Transport.VirtConsole

  defstruct [:socket_path, :transport, :transport_config, :conn, connected: false]

  # Client API

  @doc """
  Start a Shell server

  ## Options

  - `:socket_path` (required) -- unix socket path
  - `:transport` -- transport module (default: VirtConsole)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    transport = Keyword.get(opts, :transport, VirtConsole)
    transport_config = Keyword.get(opts, :transport_config, %{socket_path: socket_path})
    init_arg = {socket_path, transport, transport_config}
    GenServer.start_link(__MODULE__, init_arg, Keyword.take(opts, [:name]))
  end

  @doc """
  Wait for the guest to connect to the shell backdoor
  """
  @spec wait_for_connection(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def wait_for_connection(server, timeout \\ 30_000) do
    case wait_for_connection_with_milestones(server, timeout) do
      {:ok, _milestones} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Wait for the guest to connect and return transport-specific connection
  milestones when the transport can provide them.
  """
  @spec wait_for_connection_with_milestones(GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_connection_with_milestones(server, timeout \\ 30_000) do
    GenServer.call(server, {:wait_for_connection_with_milestones, timeout}, timeout + 5000)
  end

  @doc """
  Reconnect to the shell after a reboot

  Closes the current socket and waits for a new connection from the guest.
  """
  @spec reconnect(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def reconnect(server, timeout \\ 30_000) do
    GenServer.call(server, {:reconnect, timeout}, timeout + 5000)
  end

  @doc """
  Execute a command in the guest and return the result
  """
  @spec execute(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def execute(server, command, timeout \\ 900_000) do
    GenServer.call(server, {:execute, command}, timeout)
  end

  # Server callbacks

  @impl true
  def init({socket_path, transport, transport_config}) do
    {:ok,
     %__MODULE__{
       socket_path: socket_path,
       transport: transport,
       transport_config: transport_config
     }}
  end

  @impl true
  def handle_call(
        {:wait_for_connection, timeout},
        _from,
        %{connected: false} = state
      ) do
    case state.transport.connect(state.transport_config, timeout) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn, connected: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:wait_for_connection, _timeout}, _from, %{connected: true} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(
        {:wait_for_connection_with_milestones, timeout},
        _from,
        %{connected: false} = state
      ) do
    case connect_transport(state, timeout) do
      {:ok, conn, milestones} ->
        {:reply, {:ok, milestones}, %{state | conn: conn, connected: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:wait_for_connection_with_milestones, _timeout},
        _from,
        %{connected: true} = state
      ) do
    {:reply, {:ok, %{}}, state}
  end

  @impl true
  def handle_call({:reconnect, timeout}, _from, state) do
    if state.conn do
      state.transport.close(state.conn)
    end

    case state.transport.connect(state.transport_config, timeout) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn, connected: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | conn: nil, connected: false}}
    end
  end

  @impl true
  def handle_call({:execute, command}, _from, %{conn: conn, connected: true} = state) do
    result = do_execute(state.transport, conn, command)
    {:reply, result, state}
  end

  defp connect_transport(state, timeout) do
    Code.ensure_loaded?(state.transport)

    if function_exported?(state.transport, :connect_with_milestones, 2) do
      state.transport.connect_with_milestones(state.transport_config, timeout)
    else
      case state.transport.connect(state.transport_config, timeout) do
        {:ok, conn} -> {:ok, conn, %{}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn do
      state.transport.close(state.conn)
    end

    :ok
  end

  # Private helpers

  defp do_execute(transport, conn, command) do
    with :ok <- transport.send(conn, format_command(command)),
         {:ok, output_line} <- recv_line(transport, conn, 900_000),
         :ok <- transport.send(conn, "echo ${PIPESTATUS[0]}\n"),
         {:ok, exit_code_line} <- recv_line(transport, conn, 5000) do
      parse_output(output_line, exit_code_line)
    end
  end

  # read from transport until we get a complete line (ending with \n)
  # data may arrive in chunks across multiple recv calls
  defp recv_line(transport, conn, timeout, acc \\ "") do
    case transport.recv(conn, timeout) do
      {:ok, data} ->
        buf = acc <> data

        if String.contains?(buf, "\n") do
          [line | _rest] = String.split(buf, "\n", parts: 2)
          {:ok, line}
        else
          recv_line(transport, conn, timeout, buf)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Format a command for execution over the shell backdoor
  """
  @spec format_command(String.t()) :: String.t()
  def format_command(command) do
    escaped = String.replace(command, "'", "'\\''")
    "bash -c '#{escaped}' | (base64 -w 0; echo)\n"
  end

  @doc """
  Parse the output from a shell command execution
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
