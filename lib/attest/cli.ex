defmodule Attest.CLI do
  @moduledoc """
  Command-line interface for attest

  Accepts the same arguments as the python attest-driver, plus
  elixir-specific options. Arguments can come from CLI flags or
  environment variables (set by nix wrapProgram).
  """

  require Logger

  alias Attest.{Driver, MachineConfig, StartCommand, TestScript}

  @type parsed_args :: %{
          start_scripts: [String.t()],
          machine_config: String.t() | nil,
          vlans: [non_neg_integer()],
          test_script: String.t() | nil,
          global_timeout: non_neg_integer(),
          keep_vm_state: boolean(),
          interactive: boolean(),
          output_dir: String.t() | nil,
          help: boolean()
        }

  @doc """
  Parse CLI arguments into a structured map

  Supports both CLI flags and environment variables (env vars are
  fallbacks, CLI flags take precedence). Also recognises `eval` and
  `eval-file` subcommands for backwards compatibility.
  """
  @spec parse_args([String.t()]) :: parsed_args()
  def parse_args(args) do
    {subcommand, args} = extract_subcommand(args)

    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          interactive: :boolean,
          keep_vm_state: :boolean,
          global_timeout: :integer,
          start_scripts: :string,
          machine_config: :string,
          vlans: :string,
          test_script: :string,
          output_dir: :string
        ],
        aliases: [
          h: :help,
          i: :interactive,
          k: :keep_vm_state,
          K: :keep_vm_state,
          t: :global_timeout,
          o: :output_dir
        ]
      )

    # env var fallbacks (set by nix wrapProgram)
    machine_config =
      opts[:machine_config] || System.get_env("machineConfig")

    start_scripts_str =
      opts[:start_scripts] || System.get_env("startScripts", "")

    vlans_str =
      opts[:vlans] || System.get_env("vlans", "")

    test_script =
      opts[:test_script] || List.first(rest) || System.get_env("testScript")

    timeout_seconds = opts[:global_timeout] || env_int("globalTimeout", 3600)

    %{
      subcommand: subcommand,
      machine_config: machine_config,
      start_scripts: parse_space_separated(start_scripts_str),
      vlans: parse_vlan_list(vlans_str),
      test_script: test_script,
      global_timeout: timeout_seconds * 1000,
      keep_vm_state: opts[:keep_vm_state] || false,
      interactive: opts[:interactive] || false,
      output_dir: opts[:output_dir],
      help: opts[:help] || false
    }
  end

  @spec main([String.t()]) :: :ok
  def main(args) do
    opts = parse_args(args)

    cond do
      opts.help ->
        print_help()

      opts.subcommand != nil ->
        run_subcommand(opts.subcommand)

      opts.test_script != nil || opts.interactive ->
        run_test(opts)

      true ->
        IO.puts("attest-ng v#{Application.spec(:attest, :vsn)}")
        IO.puts("use --help for usage")
    end
  end

  defp run_subcommand({:eval, code}) do
    Code.eval_string(code)
    :ok
  end

  defp run_subcommand({:eval_file, path}) do
    Code.eval_file(path)
    :ok
  end

  defp run_test(opts) do
    # VM state (sockets, disk images) goes in a writable temp dir
    # output_dir (-o) is for screenshots and test artifacts only
    tmp_dir = System.tmp_dir!()
    state_dir = Path.join(tmp_dir, "vm-state")
    File.mkdir_p!(state_dir)
    out_dir = opts.output_dir || state_dir

    {machine_configs, vlans, global_timeout} =
      if opts.machine_config do
        build_from_machine_config(opts.machine_config, state_dir, opts)
      else
        build_from_start_scripts(opts, state_dir)
      end

    # ensure state dirs exist
    Enum.each(machine_configs, fn config ->
      File.mkdir_p!(config.state_dir)

      if Map.has_key?(config, :shared_dir) do
        File.mkdir_p!(config.shared_dir)
      end
    end)

    # copy firecracker rootfs images to writable state dirs
    # nix store files are read-only, firecracker needs write access
    Enum.each(machine_configs, fn config ->
      if Map.has_key?(config, :rootfs_source) do
        File.cp!(config.rootfs_source, config.rootfs_path)
        File.chmod!(config.rootfs_path, 0o644)
      end
    end)

    {:ok, driver} =
      Driver.start_link(
        machines: machine_configs,
        vlans: vlans,
        global_timeout: global_timeout,
        out_dir: out_dir,
        tmp_dir: state_dir
      )

    if opts.test_script do
      Logger.info("running test script: #{opts.test_script}")
      TestScript.eval_file(opts.test_script, driver)
    end

    if opts.interactive do
      Logger.info("starting interactive shell")
      IEx.start()
    end

    GenServer.stop(driver)
  end

  defp build_from_machine_config(config_path, state_dir, opts) do
    parsed = MachineConfig.parse_file(config_path, state_dir: state_dir)

    # CLI flags override JSON config values
    vlans = if opts.vlans != [], do: opts.vlans, else: parsed.vlans

    global_timeout =
      if opts.global_timeout != 3_600_000,
        do: opts.global_timeout,
        else: parsed.global_timeout

    {parsed.machines, vlans, global_timeout}
  end

  defp build_from_start_scripts(opts, state_dir) do
    machine_configs =
      Enum.map(opts.start_scripts, fn script ->
        script
        |> StartCommand.build(state_dir: state_dir)
        |> StartCommand.to_machine_config()
      end)

    {machine_configs, opts.vlans, opts.global_timeout}
  end

  defp print_help do
    IO.puts("""
    attest-ng - NixOS test driver in Elixir

    usage: attest [options] [test-script]

    options:
      -h, --help             show this help
      -i, --interactive      start interactive IEx shell
      -K, --keep-vm-state    preserve VM state between runs
      -t, --global-timeout   global timeout in seconds (default: 3600)
      -o, --output-dir       output directory for screenshots etc
      --start-scripts        space-separated VM start script paths
      --machine-config       path to JSON machine config file
      --vlans                space-separated VLAN numbers
      --test-script          path to elixir test script

    environment variables (set by nix wrapProgram):
      startScripts           space-separated VM start script paths
      machineConfig          path to JSON machine config file
      vlans                  space-separated VLAN numbers
      testScript             path to test script file
      globalTimeout          timeout in seconds

    examples:
      attest test-script.exs
      attest --interactive
      attest --start-scripts "/nix/store/.../bin/run-server-vm" test.exs
    """)
  end

  defp extract_subcommand(["eval" | rest]) do
    {{:eval, Enum.join(rest, " ")}, []}
  end

  defp extract_subcommand(["eval-file", path | _rest]) do
    {{:eval_file, path}, []}
  end

  defp extract_subcommand(args), do: {nil, args}

  defp parse_space_separated(""), do: []

  defp parse_space_separated(str) do
    str |> String.split(~r/\s+/, trim: true)
  end

  defp parse_vlan_list(""), do: []

  defp parse_vlan_list(str) do
    str
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      val -> String.to_integer(val)
    end
  end
end
