defmodule NixosTest.Machine.QMP do
  @moduledoc """
  QEMU Machine Protocol (QMP) client GenServer.

  QMP is a JSON-based protocol for communicating with QEMU. It provides:
  - VM control (start, stop, pause, resume)
  - Device management
  - Screenshots
  - Keyboard/mouse input

  ## Protocol

  Messages are newline-delimited JSON. Types:
  - Greeting: `{"QMP": {"version": ..., "capabilities": [...]}}`
  - Command: `{"execute": "cmd", "arguments": {...}}`
  - Success: `{"return": ...}`
  - Error: `{"error": {"class": "...", "desc": "..."}}`
  - Event: `{"event": "NAME", "timestamp": {...}, "data": {...}}`
  """

  use GenServer
  require Logger

  defstruct [:socket, :socket_path, events: []]

  defmodule Error do
    @moduledoc "QMP error response"
    defstruct [:class, :desc]

    @type t :: %__MODULE__{
            class: String.t(),
            desc: String.t()
          }
  end

  @type message ::
          {:greeting, map()}
          | {:ok, map()}
          | {:error, Error.t()}
          | {:event, String.t(), map()}

  @doc """
  Parse a QMP message from JSON string.
  """
  @spec parse_message(String.t()) :: message()
  def parse_message(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> parse_decoded()
  end

  defp parse_decoded(%{"QMP" => %{"version" => version}}) do
    {:greeting, version}
  end

  defp parse_decoded(%{"return" => result}) do
    {:ok, result}
  end

  defp parse_decoded(%{"error" => %{"class" => class, "desc" => desc}}) do
    {:error, %Error{class: class, desc: desc}}
  end

  defp parse_decoded(%{"event" => name, "timestamp" => timestamp}) do
    {:event, name, timestamp}
  end

  @doc """
  Encode a QMP command to JSON string (with trailing newline).
  """
  @spec encode_command(String.t(), map()) :: String.t()
  def encode_command(cmd, args \\ %{})

  def encode_command(cmd, args) when args == %{} do
    Jason.encode!(%{"execute" => cmd}) <> "\n"
  end

  def encode_command(cmd, args) do
    Jason.encode!(%{"execute" => cmd, "arguments" => args}) <> "\n"
  end

  # Client API

  @doc """
  Start a QMP client connected to the given socket path.
  """
  def start_link(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    GenServer.start_link(__MODULE__, socket_path, Keyword.take(opts, [:name]))
  end

  @doc """
  Send a command and wait for the response.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec command(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def command(server, cmd, args \\ %{}) do
    GenServer.call(server, {:command, cmd, args})
  end

  # Server callbacks

  @impl true
  def init(socket_path) do
    # connect synchronously during init
    case connect_and_negotiate(socket_path) do
      {:ok, socket} ->
        Logger.info("QMP connected to #{socket_path}")
        {:ok, %__MODULE__{socket: socket, socket_path: socket_path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:command, cmd, args}, _from, %{socket: socket} = state) do
    :ok = :gen_tcp.send(socket, encode_command(cmd, args))

    case recv_response(socket) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when not is_nil(socket) do
    :gen_tcp.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp connect_and_negotiate(socket_path) do
    with {:ok, socket} <- connect(socket_path),
         {:ok, _greeting} <- recv_greeting(socket),
         :ok <- send_capabilities(socket),
         {:ok, _response} <- recv_response(socket) do
      {:ok, socket}
    end
  end

  defp connect(socket_path) do
    :gen_tcp.connect({:local, socket_path}, 0, [:binary, {:packet, :line}, {:active, false}])
  end

  defp recv_greeting(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, line} ->
        case parse_message(String.trim_trailing(line)) do
          {:greeting, version} -> {:ok, version}
          other -> {:error, {:unexpected_message, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_capabilities(socket) do
    :gen_tcp.send(socket, encode_command("qmp_capabilities"))
  end

  defp recv_response(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, line} ->
        case parse_message(String.trim_trailing(line)) do
          {:ok, result} ->
            {:ok, result}

          {:error, error} ->
            {:error, error}

          {:event, _name, _timestamp} ->
            # skip events and keep reading for the actual response
            recv_response(socket)

          other ->
            {:error, {:unexpected_message, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
