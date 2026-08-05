# Changelog

Release-level history for completed roadmap phases. The per-task delivery ledger remains in
`roadmap/tasks.toml`; upcoming work is in `ROADMAP.md`.

## Phase 1: Extraction

- Extracted the retired TradingDashboard calculation engine into a standalone, headless
  `DeltaCalc` library with Decimal arithmetic, tests, documentation, and agent discovery.

## Phase 2: Calc primitives

- Added the dashboard-facing funding, hedging, account, concentration, margin-bridge,
  funding-projection, option-ladder, and options-risk calculation primitives.
