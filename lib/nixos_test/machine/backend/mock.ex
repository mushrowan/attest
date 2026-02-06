defmodule NixosTest.Machine.Backend.Mock do
  @moduledoc """
  Mock backend for unit tests

  Wraps injected QMP and Shell pids so Machine can be tested without
  spawning real QEMU processes. All lifecycle operations are no-ops.
  """

  @behaviour NixosTest.Machine.Backend

  alias NixosTest.Machine.QMP

  defstruct [:qmp, :shell]

  @impl true
  def init(config) do
    {:ok,
     %__MODULE__{
       qmp: Map.get(config, :qmp),
       shell: Map.get(config, :shell)
     }}
  end

  @impl true
  def start(state) do
    {:ok, state.shell, state}
  end

  @impl true
  def shutdown(_state, _timeout), do: :ok

  @impl true
  def halt(_state, _timeout), do: :ok

  @impl true
  def wait_for_shutdown(_state, _timeout), do: :ok

  @impl true
  def cleanup(_state), do: :ok

  @impl true
  def screenshot(%{qmp: nil}, _filename), do: {:error, :unsupported}

  def screenshot(%{qmp: qmp}, filename) do
    case QMP.command(qmp, "screendump", %{"filename" => filename}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_key(%{qmp: nil}, _key), do: {:error, :unsupported}

  def send_key(%{qmp: qmp}, key) do
    keys =
      key
      |> String.split("-")
      |> Enum.map(fn k -> %{"type" => "qcode", "data" => k} end)

    case QMP.command(qmp, "send-key", %{"keys" => keys}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_port_exit(state, _code), do: state

  @impl true
  def capabilities(%{qmp: qmp}) when not is_nil(qmp), do: [:screenshot, :send_key]
  def capabilities(_state), do: []
end
