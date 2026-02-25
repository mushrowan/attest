defmodule Attest.Machine.Backend.MicroVM do
  @moduledoc """
  Shared behaviour for microVM backends (firecracker, cloud-hypervisor)

  Injects common implementations for:
  - vsock shell connection
  - TAP-based network block/unblock
  - unsupported VGA/QMP/SLIRP stubs
  - private helper wrappers
  """

  defmacro __using__(_opts) do
    quote do
      alias Attest.Machine.Backend
      alias Attest.Machine.Backend.API
      alias Attest.Machine.Shell
      alias Attest.Machine.Shell.Transport.Vsock

      # unsupported — no VGA, QMP, or SLIRP

      @impl true
      def screenshot(_state, _filename), do: {:error, :unsupported}

      @impl true
      def send_key(_state, _key), do: {:error, :unsupported}

      @impl true
      def forward_port(_state, _host_port, _guest_port), do: {:error, :unsupported}

      @impl true
      def send_console(_state, _chars), do: {:error, :unsupported}

      # network control via host-side ip link

      @impl true
      def block(%{tap_interfaces: []}), do: {:error, :unsupported}

      def block(%{tap_interfaces: taps}) do
        Enum.each(taps, fn {_id, host_dev, _mac} ->
          System.cmd("ip", ["link", "set", host_dev, "down"])
        end)

        :ok
      end

      @impl true
      def unblock(%{tap_interfaces: []}), do: {:error, :unsupported}

      def unblock(%{tap_interfaces: taps}) do
        Enum.each(taps, fn {_id, host_dev, _mac} ->
          System.cmd("ip", ["link", "set", host_dev, "up"])
        end)

        :ok
      end

      @impl true
      def capabilities(_state), do: []

      # shared vsock shell connection

      defp connect_shell(state) do
        :ok = Backend.wait_for_file(state.vsock_uds_path, 30_000)

        Logger.info("connecting shell via vsock for #{state.name}")

        {:ok, shell} =
          Shell.start_link(
            socket_path: state.vsock_uds_path,
            transport: Vsock,
            transport_config: %{uds_path: state.vsock_uds_path, port: state.vsock_port}
          )

        :ok = Shell.wait_for_connection(shell, 120_000)
        state = %{state | shell: shell}

        {:ok, shell, state}
      end

      # private helper delegates

      defp stop_shell(pid), do: Backend.stop_shell(pid)
      defp close_port(port), do: Backend.close_port(port)
      defp wait_for_file(path, timeout), do: Backend.wait_for_file(path, timeout)

      defoverridable screenshot: 2,
                     send_key: 2,
                     forward_port: 3,
                     send_console: 2,
                     block: 1,
                     unblock: 1,
                     capabilities: 1
    end
  end
end
