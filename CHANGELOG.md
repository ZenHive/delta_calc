# Changelog

Release-level history for completed roadmap phases. The per-task delivery ledger remains in
`roadmap/tasks.toml`; upcoming work is in `ROADMAP.md`.

## Unreleased

- **Breaking:** `DeltaCalc.PositionCalculator.calculate_position/2` is now `calculate_position/1` —
  the unused `fee_rate` input (fee modeling belongs to `DeltaCalc.Fees`) and the echoed risk-mode
  config were removed, so the API no longer advertises inputs that don't affect the calculation.
  `Calc.dca_ladder` now actually applies the advertised `mark_buffer` to every intermediate and
  final liquidation MMR (zero preserves prior results).
- Removed baked-in venue risk constants from generic margin/liquidation math: `Calc` takes a
  caller-supplied MMR tier schedule (`:mmr_schedule`), and `MarginBridge.check_kill_switch`
  compares a per-period funding rate scaled by caller-supplied cadence against an overridable
  daily threshold. Defaults are documented conventions, not venue truths.
- Registered `DeltaCalc.Decimal` (the shared input-coercion boundary from task 39) in the
  agent manifest with `api()` annotations for `cast/1` and `cast!/1`, and hardened the
  manifest-consistency suite: every publicly documented `lib/delta_calc/` module must now be
  registered — a documented module without `api()` coverage fails CI instead of silently
  missing from the agent surface.
- Added `DeltaCalc.describe/0..2` — progressive disclosure over the manifest registry, so an
  agent narrows from library to module to function without reading source.
- **Breaking:** renamed DeltaCalc.PnL (unbackticked: the module no longer exists, and an
  ex_doc autolink would try to load it) to `DeltaCalc.Pnl`. Descripex derives discovery short
  names with `Macro.underscore/1`, which split the internal capital into `"pn_l"`; the module
  now resolves as `"pnl"`. Function names and signatures are unchanged.

## Phase 1: Extraction

- Extracted the retired TradingDashboard calculation engine into a standalone, headless
  `DeltaCalc` library with Decimal arithmetic, tests, documentation, and agent discovery.

## Phase 2: Calc primitives

- Added the dashboard-facing funding, hedging, account, concentration, margin-bridge,
  funding-projection, option-ladder, and options-risk calculation primitives.
