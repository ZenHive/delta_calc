# DeltaCalc

Pure-`Decimal` calculation engine for leveraged crypto trading — **position sizing,
effective leverage, liquidation price, DCA ladders, safety scoring, and spot hedging**.

Salvaged from the retired `TradingDashboard` app so a rebuild does not reinvent the math.
Every function is a pure value-in / value-out `Decimal` computation: no Ecto, no Phoenix,
no I/O. Drop it into any Elixir project (LiveView, CLI, Nx pipeline, agent tool) and call it.

> **Status: extraction in progress.** The calculators are being ported task-by-task from the source app.
> Track progress with `rmap list` (see `roadmap/tasks.toml`). `Calc`, `Presets`, and `Hedging` are ported.

## API surface

| Module | Responsibility |
| --- | --- |
| `DeltaCalc.Calc` | Core engine — `effective_leverage/2`, `leverage_to_aum/2`, `liquidation/4`, `allocate/5`, `position/5`, `multi_leg_position/3`, `safety/5`, `compare_dca_safety/8`, `dca_ladder/8`, `convert_ladder_for_short/1`, `quantize/1` |
| `DeltaCalc.Presets` | `load_modes/0`, `load_thresholds/0`, `load_dca_preset/0` |
| `DeltaCalc.DCAPlanner` | Planned: `calculate_dca_ladder/1` — defensive + aggressive DCA orchestration |
| `DeltaCalc.PositionCalculator` | Planned: `calculate_position/2` — full sizing pipeline, takes a plain `config` map |
| `DeltaCalc.Hedging` | Pure spot-hedging formulas — required CEX balance, coverage ratio, rebalance threshold, snapshot deltas |

## Installation (once published)

```elixir
def deps do
  [{:delta_calc, "~> 0.1"}]
end
```

## Provenance

Extracted from `TradingDashboard.Risk.*` (the `Calc`/`Presets`/`DCAPlanner`/`PositionCalculator`
modules) plus the pure hedging formulas from its `Portfolio` context. The original modules carry
~100 unit + StreamData property tests, ported alongside the code.

## Development

```bash
mix deps.get
mix test            # or: mix test.json
mix precommit       # format + credo + doctor + tests
mix precommit.full  # + dialyzer
```
