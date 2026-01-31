defmodule NixosTest.CLI do
  @moduledoc """
  Command-line interface for nixos-test.
  """

  def main(args) do
    args
    |> parse_args()
    |> run()
  end

  defp parse_args(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          interactive: :boolean,
          keep_vm_state: :boolean,
          timeout: :integer
        ],
        aliases: [
          h: :help,
          i: :interactive,
          k: :keep_vm_state,
          t: :timeout
        ]
      )

    {opts, rest}
  end

  defp run({opts, _rest}) do
    if opts[:help] do
      print_help()
    else
      IO.puts("nixos-test-ng v#{Application.spec(:nixos_test, :vsn)}")
      IO.puts("")
      IO.puts("not yet implemented - see ARCHITECTURE.md for design")

      if opts[:interactive] do
        IO.puts("")
        IO.puts("starting interactive shell...")
        IEx.start()
      end
    end
  end

  defp print_help do
    IO.puts("""
    nixos-test-ng - NixOS test driver in Elixir

    usage: nixos-test [options] <test-script>

    options:
      -h, --help           show this help
      -i, --interactive    start interactive IEx shell
      -k, --keep-vm-state  preserve VM state between runs
      -t, --timeout        global timeout in seconds (default: 3600)

    examples:
      nixos-test ./result/test-script
      nixos-test -i ./result/test-script
    """)
  end
end
