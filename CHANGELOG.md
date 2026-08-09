# Changelog

Release-level history for completed roadmap phases. The per-task delivery ledger remains in
`roadmap/tasks.toml`; upcoming work is in `ROADMAP.md`.

## Unreleased

- Split the `Calc` god-module along cohesion seams into `DeltaCalc.Leverage`, `Liquidation`,
  `Allocation`, `Safety`, and `Quantization` (DCA-ladder logic moved to `DCAPlanner`).
  `DeltaCalc.Calc` remains as an undocumented compatibility façade delegating all 11 previous
  public functions; the agent manifest advertises the extracted modules instead.
- **Breaking:** moved rounding to explicit caller-controlled output boundaries — generic
  price/rate/percentage/ratio math no longer quantizes internally and returns full active
  `Decimal.Context` precision (34 under decimal 3.x). `OptionLadder` strike rounding takes
  caller `:strike_increment` + `:rounding_mode`; whole-day rounding in `FundingProjection`/
  `MarginBridge` is documented as intrinsic. `Calc.quantize/1` remains only as the documented
  eight-place legacy compatibility boundary.
- Advertised every exact Decimal money/price/rate `:value` input as a canonical JSON-string
  contract across all calculation modules (matching the `DeltaCalc.Decimal` coercion boundary);
  a manifest-wide CI invariant now rejects any MCP input schema advertising `{"type": "number"}`.
- Made `Calc.multi_leg_position` public and side-aware (`side` defaults to `:long`), so short
  multi-leg positions reach the existing side-aware math through a documented API.
- Added base-numeraire math to `DeltaCalc.DeltaNeutral`: inverse-perp exposure, settlement-period
  net-delta handling, covered-call coverage (capacity/uncovered reporting without implying
  approval), and risk-target checks.
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
