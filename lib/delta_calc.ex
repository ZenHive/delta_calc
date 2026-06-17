defmodule DeltaCalc do
  @moduledoc """
  Pure-`Decimal` calculation engine for leveraged crypto trading.

  Salvaged from the retired `TradingDashboard` app (`TradingDashboard.Risk.*` +
  the hedging formulas in its `Portfolio` context) into a standalone, headless
  library so the rebuild does not reinvent the math. Every function is a pure
  value-in / value-out `Decimal` computation — no Ecto, no Phoenix, no I/O.

  ## Modules

    * `DeltaCalc.Calc` — core engine: effective leverage, leverage-to-AUM,
      liquidation price, allocation envelope, position sizing, multi-leg
      cross-margin aggregation, safety scoring, DCA ladders.
    * `DeltaCalc.Presets` — default risk modes, black-swan thresholds, DCA preset.
    * `DeltaCalc.DCAPlanner` — defensive/aggressive DCA ladder orchestration.
    * `DeltaCalc.PositionCalculator` — full position-sizing pipeline
      (takes a plain `config` map; decoupled from LiveView assigns).
    * `DeltaCalc.Hedging` — pure spot-hedging formulas: required CEX balance,
      hedge coverage ratio, rebalance threshold, snapshot deltas.

  ## Agent surface

  Every public function is annotated with an `api/3` declaration (via Descripex), so the
  engine is discoverable and callable by AI agents (`__api__/0`, JSON Schema, MCP
  tools via `Descripex.MCP.tools/1`, aggregated by `DeltaCalc.Manifest`). A trading
  agent can plan a position or size a hedge by calling DeltaCalc as a tool.

  ## Manifest

  `DeltaCalc.Manifest.build/0` aggregates the full agent surface; `DeltaCalc.Manifest.tools/0`
  exposes the same APIs as MCP tool definitions for trading agents.
  """
end
