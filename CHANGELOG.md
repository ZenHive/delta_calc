# Changelog

Release-level history for completed roadmap phases. The per-task delivery ledger remains in
`roadmap/tasks.toml`; upcoming work is in `ROADMAP.md`.

## Unreleased

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
