# Changelog

Release-level history for completed roadmap phases. The per-task delivery ledger remains in
`roadmap/tasks.toml`; upcoming work is in `ROADMAP.md`.

## Unreleased

- Every README example is now executed by `mix ci`
  (`test/delta_calc/readme_examples_test.exs`): each ```elixir block carrying a `#=>` result is
  evaluated with the README's own aliases and asserted to render exactly as documented
  (`Decimal` compared as `Decimal`, scale significant), with a pinned asserted/elided census so a
  new elision cannot quietly opt an example out. README drift — the class that left the front
  door raising `ArgumentError` and documenting a 100x funding cost — is a red CI run instead of a
  consumer discovery.
- Documented the signed accrued-funding convention on `DeltaCalc.Pnl.realized_pnl/1` and
  `breakeven/1` (negative when paid, positive when received), which the delegate
  `Fees.funding_adjusted_breakeven/3` already stated but the `Pnl` docs and agent schemas did
  not — an MCP consumer reading `Pnl`'s schema had no way to know a bare positive value means
  funding *received*. Behavior unchanged; the direction is now pinned by domain-invariant tests.

- **Breaking:** `DeltaCalc.Liquidation.liquidation/4` (and the `Calc` façade, `AccountMetrics`,
  `PositionCalculator`, and `DCAPlanner` paths that build on it) now prices a single position
  with the published venue cross-margin formula — `entry * (1 - 1/leff) / (1 - mmr)` long,
  `entry * (1 + 1/leff) / (1 + mmr)` short — instead of the old
  `entry * (1 -/+ (1 - mmr)/leff)`, which divided maintenance margin by leverage in a way no
  venue does. Liquidation prices, liquidation distances, and every derived safety verdict move.

## 0.3.0 - 2026-08-10

Completes milestones v0_3 (consumer decision primitives) and v0_4 (base-numeraire
covered-call math).

- Split the `Calc` god-module along cohesion seams into `DeltaCalc.Leverage`, `Liquidation`,
  `Allocation`, `Safety`, and `Quantization` (DCA-ladder logic moved to `DCAPlanner`).
  DeltaCalc.Calc remains as an undocumented compatibility façade delegating all 11 previous
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
- **Breaking:** DeltaCalc.PositionCalculator.calculate_position/2 (removed) is now
  `DeltaCalc.PositionCalculator.calculate_position/1` —
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

- **Breaking:** standardized the funding-rate unit to a decimal fraction (`0.0001` = 0.01%)
  across the whole surface. `MarginBridge.stress_test_prolonged_negative` /
  `check_kill_switch` and the `OptionsRisk` functions delegating to them no longer divide the
  rate by 100 internally, so a rate derived once is now dimensionally consistent whether it is
  fed to `Funding`, `Carry`, `Hedging`, or `MarginBridge` — previously the same number meant a
  100x different rate depending on the module.
- Fixed the inverted raw→daily scaling in `Funding.find_arbitrage_opportunities/2`. `min_delta`
  stays a raw per-period threshold; entries tagged `:daily_normalized` now compare against
  `min_delta` **multiplied** by periods-per-day (daily = raw x periods, so the daily-basis
  threshold is larger), where the previous code divided and let through spreads well under the
  requested floor.
- Fixed `PortfolioMargin` netting for offsetting legs marked at different prices: the netted
  mark is now signed notional over net quantity, not a gross-quantity-weighted average mark
  applied to the net quantity — which was not the net position's mark and skewed both
  `combined_maintenance_margin/1` and `portfolio_liquidation_price/1`.
- **Breaking:** `StressScenario.apply_shock/2` no longer copies a book-wide verdict onto each
  position. The per-position `:liquidated?` field is gone; the result carries a single
  book-wide `:portfolio_liquidated?` instead, so a healthy leg no longer reports itself
  liquidated whenever the book as a whole is under water.
- **Breaking:** moved presentation strings out of `OptionsRisk.stress_test_extended_negative/2`.
  Each scenario's `:margin_impact` is a `Decimal` ratio of free headroom rather than a string
  like `"+45%"`, and the prose `:kill_switch_trigger` / `:recommendation` fields are replaced by
  numeric `:kill_switch_day_min` / `:kill_switch_day_max`, so consumers no longer regex numbers
  back out of a pure-calc result.
- **Breaking:** disambiguated zero-as-sentinel from a legitimate zero in the `Calc` returns
  (`effective_leverage`, `liquidation`, `leverage_to_aum`, `safety`). Invalid input — zero
  equity, non-positive entry — returns `{:error, reason}` instead of a `0` a consumer cannot
  tell apart from "no liquidation risk"; `AccountMetrics.calculate/1,2` propagates the error.
- Replaced formula-derived golden fixtures with independently sourced values (hand-computed or
  from a published venue spec, with documented provenance), compared as `Decimal` with explicit
  tolerances instead of `to_float` — a golden derived from the formula under test proves
  consistency, not correctness.

## Phase 1: Extraction

- Extracted the retired TradingDashboard calculation engine into a standalone, headless
  `DeltaCalc` library with Decimal arithmetic, tests, documentation, and agent discovery.

## Phase 2: Calc primitives

- Added the dashboard-facing funding, hedging, account, concentration, margin-bridge,
  funding-projection, option-ladder, and options-risk calculation primitives.
