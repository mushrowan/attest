defmodule NixosTest.Machine.QMP do
  @moduledoc """
  QEMU Machine Protocol (QMP) client.

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
end
