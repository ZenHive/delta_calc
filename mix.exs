defmodule DeltaCalc.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :delta_calc,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 80]],
      dialyzer: [
        plt_add_apps: [:mix],
        list_unused_filters: true,
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ],
      name: "DeltaCalc",
      description:
        "Pure-Decimal calculation engine for leveraged crypto trading: position sizing, " <>
          "effective leverage, liquidation, DCA ladders, safety scoring, and spot hedging.",
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: ["test.json": :test, "dialyzer.json": :dev]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:decimal, "~> 2.0"},

      # Test / property-based testing (ported risk tests rely on StreamData)
      {:stream_data, "~> 1.0", only: [:test, :dev]},

      # Dev / quality tooling — mirrors the source project's stack
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22.0", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.5", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_unit_json, "~> 0.5", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warning-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict --all",
        "doctor",
        "test.json --quiet --cover"
      ],
      "precommit.full": ["precommit", "cmd env MIX_ENV=dev mix dialyzer"]
    ]
  end

  defp docs do
    [
      main: "DeltaCalc",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
