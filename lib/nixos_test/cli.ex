defmodule NixosTest.CLI do
  @moduledoc """
  Command-line interface for nixos-test

  Accepts the same arguments as the python nixos-test-driver, plus
  elixir-specific options. Arguments can come from CLI flags or
  environment variables (set by nix wrapProgram).
  """

  require Logger

  alias NixosTest.{Driver, StartCommand, TestScript}

  @type parsed_args :: %{
          start_scripts: [String.t()],
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
    start_scripts_str =
      opts[:start_scripts] || System.get_env("startScripts", "")

    vlans_str =
      opts[:vlans] || System.get_env("vlans", "")

    test_script =
      opts[:test_script] || List.first(rest) || System.get_env("testScript")

    timeout_seconds = opts[:global_timeout] || env_int("globalTimeout", 3600)

    %{
      subcommand: subcommand,
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
        IO.puts("nixos-test-ng v#{Application.spec(:nixos_test, :vsn)}")
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
    state_dir = Path.join(tmp_dir, "vm-state-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(state_dir)
    out_dir = opts.output_dir || state_dir

    # build machine configs from start scripts
    machine_configs =
      Enum.map(opts.start_scripts, fn script ->
        script
        |> StartCommand.build(state_dir: state_dir)
        |> StartCommand.to_machine_config()
      end)

    # ensure state dirs exist
    Enum.each(machine_configs, fn config ->
      File.mkdir_p!(config.state_dir)
      File.mkdir_p!(config.shared_dir)
    end)

    {:ok, driver} =
      Driver.start_link(
        machines: machine_configs,
        vlans: opts.vlans,
        global_timeout: opts.global_timeout,
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

  defp print_help do
    IO.puts("""
    nixos-test-ng - NixOS test driver in Elixir

    usage: nixos-test [options] [test-script]

    options:
      -h, --help             show this help
      -i, --interactive      start interactive IEx shell
      -K, --keep-vm-state    preserve VM state between runs
      -t, --global-timeout   global timeout in seconds (default: 3600)
      -o, --output-dir       output directory for screenshots etc
      --start-scripts        space-separated VM start script paths
      --vlans                space-separated VLAN numbers
      --test-script          path to elixir test script

    environment variables (set by nix wrapProgram):
      startScripts           space-separated VM start script paths
      vlans                  space-separated VLAN numbers
      testScript             path to test script file
      globalTimeout          timeout in seconds

    examples:
      nixos-test test-script.exs
      nixos-test --interactive
      nixos-test --start-scripts "/nix/store/.../bin/run-server-vm" test.exs
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
