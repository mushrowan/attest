defmodule NixosTest.Machine.Backend do
  @moduledoc """
  Behaviour for VM backends

  Each backend owns the full boot sequence: process spawning, control plane
  connection, and shell setup. Machine delegates all backend-specific operations
  through this interface.

  Optional capabilities (screenshot, send_key) return `{:error, :unsupported}`
  when the backend doesn't support them.
  """

  @type config :: map()
  @type state :: term()

  # lifecycle
  @callback init(config) :: {:ok, state}
  @callback start(state) :: {:ok, shell_pid :: pid(), state} | {:error, term()}
  @callback shutdown(state, timeout()) :: :ok | {:error, term()}
  @callback halt(state, timeout()) :: :ok | {:error, term()}
  @callback wait_for_shutdown(state, timeout()) :: :ok | {:error, :timeout}
  @callback cleanup(state) :: :ok

  # optional capabilities — return {:error, :unsupported} if not available
  @callback screenshot(state, filename :: String.t()) :: :ok | {:error, term()}
  @callback send_key(state, key :: String.t()) :: :ok | {:error, term()}
  @callback block(state) :: :ok | {:error, term()}
  @callback unblock(state) :: :ok | {:error, term()}
  @callback forward_port(state, host_port :: non_neg_integer(), guest_port :: non_neg_integer()) ::
              :ok | {:error, term()}
  @callback send_console(state, chars :: String.t()) :: :ok | {:error, term()}

  # snapshots — return {:error, :unsupported} if not available
  @callback snapshot_create(state, snapshot_dir :: String.t()) :: :ok | {:error, term()}
  @callback snapshot_load(state, snapshot_dir :: String.t()) :: :ok | {:error, term()}

  # port messages (called by Machine's handle_info)
  @callback handle_port_exit(state, exit_code :: non_neg_integer()) :: state

  # introspection
  @callback capabilities(state) :: [:screenshot | :send_key | :network_control | :port_forward]
end
