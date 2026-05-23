defmodule Attest.MixProject do
  use Mix.Project

  def project do
    [
      app: :attest,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases(),

      # dialyzer
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix]
      ],
      xref: [exclude: [Jason]],
      test_coverage: test_coverage(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ],
      aliases: [
        "deps.nix": ["cmd mix2nix > nix/mix-deps.nix"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh, :public_key],
      mod: {Attest.Application, []}
    ]
  end

  defp deps do
    [
      # json for QMP protocol
      {:jason, "~> 1.4"},

      # dev/test tools
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :dev, runtime: false},
      {:castore, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp test_coverage do
    if Code.ensure_loaded?(ExCoveralls) do
      [tool: ExCoveralls]
    else
      []
    end
  end

  defp escript do
    [main_module: Attest.CLI]
  end

  defp releases do
    [
      attest: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
