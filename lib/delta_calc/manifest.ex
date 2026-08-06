defmodule DeltaCalc.Manifest do
  @moduledoc """
  Aggregates the Descripex-annotated API surface for agent discovery and MCP tooling.

  Use `build/0` for a JSON-serializable manifest, or `tools/0` for MCP tool definitions
  that a trading agent can call directly.

  CI enforces four global invariants in `DeltaCalc.ManifestConsistencyTest`:

    1. Public function name+arity is unique across all `@modules` entries.
    2. Every `lib/delta_calc/` module exposing `api()` functions is listed in `@modules`.
    3. Every advertised public function carries Descripex `:hints` metadata.
    4. Every public function in a registered module is advertised via `api()`.
  """

  @modules [
    DeltaCalc.Calc,
    DeltaCalc.Presets,
    DeltaCalc.DCAPlanner,
    DeltaCalc.PositionCalculator,
    DeltaCalc.Hedging,
    DeltaCalc.Funding,
    DeltaCalc.AccountMetrics,
    DeltaCalc.Concentration,
    DeltaCalc.MarginBridge,
    DeltaCalc.FundingProjection,
    DeltaCalc.OptionLadder,
    DeltaCalc.OptionsRisk,
    DeltaCalc.Pnl,
    DeltaCalc.DeltaNeutral,
    DeltaCalc.PortfolioMargin,
    DeltaCalc.StressScenario,
    DeltaCalc.Fees,
    DeltaCalc.Carry
  ]

  @doc "Build a JSON-serializable manifest of all public DeltaCalc APIs."
  @spec build() :: map()
  def build, do: Descripex.Manifest.build(@modules)

  @doc "Return MCP tool definitions for all public DeltaCalc APIs."
  @spec tools(keyword()) :: [map()]
  def tools(opts \\ []), do: Descripex.MCP.tools(@modules, opts)

  @doc "Return the list of modules included in the manifest."
  @spec modules() :: [module()]
  def modules, do: @modules
end
