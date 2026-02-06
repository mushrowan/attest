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
  def block(%{qmp: nil}), do: {:error, :unsupported}

  def block(%{qmp: qmp}) do
    case QMP.command(qmp, "set_link", %{"name" => "virtio-net-pci.1", "up" => false}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def unblock(%{qmp: nil}), do: {:error, :unsupported}

  def unblock(%{qmp: qmp}) do
    case QMP.command(qmp, "set_link", %{"name" => "virtio-net-pci.1", "up" => true}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def forward_port(%{qmp: nil}, _host_port, _guest_port), do: {:error, :unsupported}

  def forward_port(%{qmp: qmp}, host_port, guest_port) do
    cmd = "hostfwd_add tcp::#{host_port}-:#{guest_port}"

    case QMP.command(qmp, "human-monitor-command", %{"command-line" => cmd}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_console(_state, _chars), do: {:error, :unsupported}

  @impl true
  def snapshot_create(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def snapshot_load(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def restore_from_snapshot(_state, _snapshot_dir), do: {:error, :unsupported}

  @impl true
  def handle_port_exit(state, _code), do: state

  @impl true
  def capabilities(%{qmp: qmp}) when not is_nil(qmp),
    do: [:screenshot, :send_key, :network_control, :port_forward]

  def capabilities(_state), do: []
end
