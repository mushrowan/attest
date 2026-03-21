defmodule Attest.Machine.Shell.Transport.SSH do
  @moduledoc """
  SSH shell transport

  Connects to a remote host over SSH, opens a shell channel, and
  bridges it to the Shell command protocol via a GenServer that
  buffers channel data.

  ## Config

  Required keys:
  - `:host` -- hostname or IP address
  - `:user` -- SSH username

  Authentication (one of):
  - `:password` -- password string
  - `:user_dir` -- path to directory containing user keys (id_rsa etc)

  Optional keys:
  - `:port` -- SSH port (default: 22)
  """

  @behaviour Attest.Machine.Shell.Transport

  require Logger

  alias __MODULE__.Bridge

  @impl true
  def connect(config, timeout) do
    host = config |> Map.fetch!(:host) |> String.to_charlist()
    port = Map.get(config, :port, 22)
    user = config |> Map.fetch!(:user) |> String.to_charlist()
    opts = build_connect_opts(config, user)

    Logger.info("SSH connecting to #{config.host}:#{port}")

    with {:ok, conn_ref} <- :ssh.connect(host, port, opts, timeout) do
      Bridge.start_link(conn_ref, timeout)
    end
  end

  @impl true
  def send(bridge, data), do: Bridge.send(bridge, data)

  @impl true
  def recv(bridge, timeout), do: Bridge.recv(bridge, timeout)

  @impl true
  def close(bridge), do: Bridge.stop(bridge)

  defp build_connect_opts(config, user) do
    # always set user_dir to avoid ssh_file trying to access ~/.ssh
    # which fails in sandboxed environments (nix build, CI)
    user_dir =
      if Map.has_key?(config, :user_dir) do
        String.to_charlist(config.user_dir)
      else
        tmp = Path.join(System.tmp_dir!(), "attest-ssh-#{:rand.uniform(100_000)}")
        File.mkdir_p!(tmp)
        String.to_charlist(tmp)
      end

    opts = [
      {:user, user},
      {:user_dir, user_dir},
      {:silently_accept_hosts, true},
      {:user_interaction, false}
    ]

    if Map.has_key?(config, :password) do
      [{:password, String.to_charlist(config.password)} | opts]
    else
      opts
    end
  end
end

defmodule Attest.Machine.Shell.Transport.SSH.Bridge do
  @moduledoc false
  # GenServer that owns an SSH channel and provides synchronous
  # send/recv for the Shell command protocol. Receives SSH channel
  # messages ({:ssh_cm, ...}) and buffers data for recv callers.

  use GenServer

  defstruct [:conn_ref, :channel_id, :waiting, buffer: <<>>, closed: false]

  def start_link(conn_ref, timeout) do
    GenServer.start_link(__MODULE__, {conn_ref, timeout})
  end

  def send(bridge, data) do
    GenServer.call(bridge, {:send, data})
  end

  def recv(bridge, timeout) do
    GenServer.call(bridge, {:recv, timeout}, timeout + 5000)
  end

  def stop(bridge) do
    GenServer.stop(bridge)
  end

  # callbacks

  @impl true
  def init({conn_ref, timeout}) do
    case :ssh_connection.session_channel(conn_ref, timeout) do
      {:ok, channel_id} ->
        case :ssh_connection.shell(conn_ref, channel_id) do
          ok when ok in [:ok, :success] ->
            {:ok, %__MODULE__{conn_ref: conn_ref, channel_id: channel_id}}

          :failure ->
            :ssh.close(conn_ref)
            {:stop, :shell_request_failed}
        end

      {:error, reason} ->
        :ssh.close(conn_ref)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, data}, _from, state) do
    result = :ssh_connection.send(state.conn_ref, state.channel_id, data)
    {:reply, result, state}
  end

  def handle_call({:recv, _timeout}, _from, %{buffer: buffer} = state)
      when byte_size(buffer) > 0 do
    {:reply, {:ok, buffer}, %{state | buffer: <<>>}}
  end

  def handle_call({:recv, _timeout}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:recv, timeout}, from, %{buffer: <<>>} = state) do
    timer = Process.send_after(self(), {:recv_timeout, from}, timeout)
    {:noreply, %{state | waiting: {from, timer}}}
  end

  @impl true
  def handle_info({:ssh_cm, _, {:data, _, 0, data}}, %{waiting: {from, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, data})
    {:noreply, %{state | waiting: nil}}
  end

  def handle_info({:ssh_cm, _, {:data, _, 0, data}}, state) do
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  # stderr data (type 1) -- append to buffer too
  def handle_info({:ssh_cm, _, {:data, _, 1, data}}, %{waiting: {from, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, data})
    {:noreply, %{state | waiting: nil}}
  end

  def handle_info({:ssh_cm, _, {:data, _, 1, data}}, state) do
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  def handle_info({:ssh_cm, _, {:eof, _}}, %{waiting: {from, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:error, :closed})
    {:noreply, %{state | waiting: nil, closed: true}}
  end

  def handle_info({:ssh_cm, _, {:eof, _}}, state) do
    {:noreply, %{state | closed: true}}
  end

  def handle_info({:ssh_cm, _, {:closed, _}}, %{waiting: {from, timer}} = state) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:error, :closed})
    {:noreply, %{state | waiting: nil, closed: true}}
  end

  def handle_info({:ssh_cm, _, {:closed, _}}, state) do
    {:noreply, %{state | closed: true}}
  end

  def handle_info({:ssh_cm, _, {:exit_status, _, _}}, state) do
    {:noreply, state}
  end

  def handle_info({:recv_timeout, from}, state) do
    case state.waiting do
      {^from, _} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: nil}}

      _ ->
        # stale timeout after data arrived
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn_ref do
      :ssh.close(state.conn_ref)
    end

    :ok
  end
end
