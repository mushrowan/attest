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

  use GenServer
  require Logger

  defstruct [:socket_path, :listen_socket, :socket, connected: false]

  @backdoor_ready "Spawning backdoor root shell..."

  # Client API

  @doc """
  Start a Shell server that listens on the given socket path.
  """
  def start_link(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    GenServer.start_link(__MODULE__, socket_path, Keyword.take(opts, [:name]))
  end

  @doc """
  Wait for the guest to connect to the shell backdoor.
  """
  @spec wait_for_connection(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def wait_for_connection(server, timeout \\ 30_000) do
    GenServer.call(server, {:wait_for_connection, timeout}, timeout + 5000)
  end

  @doc """
  Execute a command in the guest and return the result.
  """
  @spec execute(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def execute(server, command, timeout \\ 900_000) do
    GenServer.call(server, {:execute, command}, timeout)
  end

  # Server callbacks

  @impl true
  def init(socket_path) do
    # ensure clean socket
    File.rm(socket_path)

    case :gen_tcp.listen(0, [
           :binary,
           {:packet, :line},
           {:active, false},
           {:ip, {:local, socket_path}}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("shell listening on #{socket_path}")
        {:ok, %__MODULE__{socket_path: socket_path, listen_socket: listen_socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:wait_for_connection, timeout},
        _from,
        %{listen_socket: listen, connected: false} = state
      ) do
    case :gen_tcp.accept(listen, timeout) do
      {:ok, socket} ->
        case wait_for_backdoor_ready(socket, timeout) do
          :ok ->
            Logger.info("shell backdoor connected")
            {:reply, :ok, %{state | socket: socket, connected: true}}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:wait_for_connection, _timeout}, _from, %{connected: true} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:execute, command}, _from, %{socket: socket, connected: true} = state) do
    result = do_execute(socket, command)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, %{socket: socket, listen_socket: listen}) do
    if socket, do: :gen_tcp.close(socket)
    if listen, do: :gen_tcp.close(listen)
    :ok
  end

  # Private helpers

  defp wait_for_backdoor_ready(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        if String.contains?(line, @backdoor_ready) do
          :ok
        else
          # keep reading until we see the ready message
          wait_for_backdoor_ready(socket, timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_execute(socket, command) do
    # send command
    case :gen_tcp.send(socket, format_command(command)) do
      :ok ->
        # receive base64 output
        case :gen_tcp.recv(socket, 0, 900_000) do
          {:ok, output_line} ->
            # request exit code
            :ok = :gen_tcp.send(socket, "echo ${PIPESTATUS[0]}\n")

            # receive exit code
            case :gen_tcp.recv(socket, 0, 5000) do
              {:ok, exit_code_line} ->
                parse_output(String.trim_trailing(output_line), exit_code_line)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
