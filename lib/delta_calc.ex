defmodule DeltaCalc do
  @moduledoc """
  Pure-`Decimal` calculation engine for leveraged crypto trading.

  Salvaged from the retired `TradingDashboard` app (`TradingDashboard.Risk.*` +
  the hedging formulas in its `Portfolio` context) into a standalone, headless
  library so the rebuild does not reinvent the math. Every function is a pure
  value-in / value-out `Decimal` computation — no Ecto, no Phoenix, no I/O.

  ## Modules

    * `DeltaCalc.Leverage` — effective leverage, position sizing, and multi-leg aggregation.
    * `DeltaCalc.Liquidation` — simplified long/short liquidation estimates.
    * `DeltaCalc.Allocation` — subaccount allocation envelopes.
    * `DeltaCalc.Safety` — safety scoring and before/after DCA comparisons.
    * `DeltaCalc.Presets` — default risk modes, black-swan thresholds, DCA preset.
    * `DeltaCalc.DCAPlanner` — DCA ladder math, presets, and orchestration.
    * `DeltaCalc.Quantization` — retired-dashboard output compatibility.
    * `DeltaCalc.Calc` — compatibility façade over these focused modules.
    * `DeltaCalc.PositionCalculator` — full position-sizing pipeline
      (takes a plain `config` map; decoupled from LiveView assigns).
    * `DeltaCalc.Hedging` — pure spot-hedging formulas: required CEX balance,
      hedge coverage ratio, rebalance threshold, snapshot deltas.

  ## Agent surface

  Every manifest module's public function is annotated with an `api/3` declaration (via
  Descripex), so the engine is discoverable and callable by AI agents (`__api__/0`, JSON Schema, MCP
  tools via `Descripex.MCP.tools/1`, aggregated by `DeltaCalc.Manifest`). A trading
  agent can plan a position or size a hedge by calling DeltaCalc as a tool.

  ## Manifest

  `DeltaCalc.Manifest.build/0` aggregates the full agent surface; `DeltaCalc.Manifest.tools/0`
  exposes the same APIs as MCP tool definitions for trading agents.

  ## Discovery

  `describe/0..2` is the progressive-disclosure entry point over the same module list —
  an agent narrows from library to module to function without reading source:

      DeltaCalc.describe()                          # L1: every module, namespace, function count
      DeltaCalc.describe("hedging")                 # L2: that module's functions, arity, spec
      DeltaCalc.describe("hedging", :check_hedge_coverage)   # L3: params, kinds, returns, errors

  Short names are the module's last segment underscored (`DeltaCalc.DCAPlanner` →
  `"dca_planner"`), accepted as a string or an atom; the full module atom works too.
  """

  # Single registry: the discovery surface and the MCP/manifest surface both read
  # DeltaCalc.Manifest.modules/0, so they cannot drift apart. Descripex documents
  # :modules as a literal list — passing a call works because the macro unquotes the
  # argument unevaluated into each generated body. DiscoverableTest pins the equality
  # with Manifest.modules/0; if a future Descripex normalizes the option at expansion
  # time, fix this call site rather than duplicating the list.
  use Descripex.Discoverable, modules: DeltaCalc.Manifest.modules()
end
