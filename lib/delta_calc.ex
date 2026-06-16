defmodule DeltaCalc do
  @moduledoc """
  Pure-`Decimal` calculation engine for leveraged crypto trading.

  Salvaged from the retired `TradingDashboard` app (`TradingDashboard.Risk.*` +
  the hedging formulas in its `Portfolio` context) into a standalone, headless
  library so the rebuild does not reinvent the math. Every function is a pure
  value-in / value-out `Decimal` computation — no Ecto, no Phoenix, no I/O.

  ## Modules (target API surface — ported task-by-task, see `roadmap/`)

    * `DeltaCalc.Calc` — core engine: effective leverage, leverage-to-AUM,
      liquidation price, allocation envelope, position sizing, multi-leg
      cross-margin aggregation, safety scoring, DCA ladders.
    * `DeltaCalc.Presets` — default risk modes, black-swan thresholds, DCA preset.
    * `DeltaCalc.DCAPlanner` — defensive/aggressive DCA ladder orchestration.
    * `DeltaCalc.PositionCalculator` — full position-sizing pipeline
      (takes a plain `config` map; decoupled from LiveView assigns).
    * `DeltaCalc.Hedging` — pure spot-hedging formulas: required CEX balance,
      hedge coverage ratio, rebalance threshold, snapshot deltas.

  > #### Scaffold {: .info}
  > This is the library skeleton. The calculators are ported incrementally
  > against the extraction roadmap in `roadmap/tasks.toml` (`rmap list`).
  """
end
