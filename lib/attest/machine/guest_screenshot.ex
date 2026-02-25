defmodule Attest.Machine.GuestScreenshot do
  @moduledoc """
  In-guest screenshot capture for non-QEMU backends

  Since microVM backends (firecracker, cloud-hypervisor) have no VGA
  or QMP, screenshots are taken inside the guest via the shell backdoor
  and transferred back as base64.

  Supports three capture methods:
  - `:fbgrab` — linux framebuffer capture (virtual console, no X needed)
  - `:x11` — X11 root window capture via imagemagick's `import`
  - `:grim` — wayland screenshot via grim

  The guest NixOS config must include the required tools. Example:

      { pkgs, ... }: {
        environment.systemPackages = [ pkgs.fbgrab ];  # for :fbgrab
        # or: [ pkgs.imagemagick pkgs.xorg.xwd ];      # for :x11
        # or: [ pkgs.grim ];                            # for :grim
      }

  ## Usage from test scripts

      # take screenshot and save to host
      guest_screenshot(machine, "/tmp/screen.png")

      # with explicit method
      guest_screenshot(machine, "/tmp/screen.png", method: :x11)
  """

  require Logger

  @tmp_path "/tmp/attest-screenshot"

  @doc """
  Take a screenshot via the guest shell and save to a host file

  Options:
  - `:method` — capture method (`:fbgrab`, `:x11`, `:grim`), default: `:fbgrab`
  - `:display` — X11 display (default: `:0`), only used with `:x11`
  """
  @spec capture(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def capture(machine, host_path, opts \\ []) do
    method = Keyword.get(opts, :method, :fbgrab)
    guest_path = "#{@tmp_path}-#{:rand.uniform(100_000)}.png"
    capture_cmd = build_capture_command(method, guest_path, opts)

    with {0, _output} <- Attest.Machine.execute(machine, capture_cmd),
         :ok <- transfer_to_host(machine, guest_path, host_path),
         {_, _} <- Attest.Machine.execute(machine, "rm -f #{guest_path}") do
      :ok
    else
      {code, output} when is_integer(code) ->
        {:error, {:capture_failed, code, output}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Build the guest-side capture command for a given method
  """
  @spec build_capture_command(atom(), String.t(), keyword()) :: String.t()
  def build_capture_command(method, path \\ "#{@tmp_path}.png", opts \\ [])

  def build_capture_command(:fbgrab, path, _opts) do
    "fbgrab -c /dev/tty1 #{path}"
  end

  def build_capture_command(:x11, path, opts) do
    display = Keyword.get(opts, :display, ":0")
    "DISPLAY=#{display} import -window root #{path}"
  end

  def build_capture_command(:grim, path, _opts) do
    "grim #{path}"
  end

  @doc """
  Build command to transfer a guest file to host via base64
  """
  @spec transfer_command(String.t()) :: String.t()
  def transfer_command(guest_path) do
    "base64 -w 0 #{guest_path}"
  end

  defp transfer_to_host(machine, guest_path, host_path) do
    case Attest.Machine.execute(machine, transfer_command(guest_path)) do
      {0, encoded} ->
        case Base.decode64(String.trim(encoded)) do
          {:ok, content} ->
            File.mkdir_p!(Path.dirname(host_path))
            File.write!(host_path, content)
            :ok

          :error ->
            {:error, :decode_failed}
        end

      {code, output} when is_integer(code) ->
        {:error, {:transfer_failed, code, output}}

      {:error, _} = err ->
        err
    end
  end
end
