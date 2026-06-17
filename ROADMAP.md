# DeltaCalc Roadmap

Salvage the calculation engine from the retired **TradingDashboard** app into a standalone,
headless library so the rebuild depends on `DeltaCalc` instead of reimplementing the math.

Source of truth: `roadmap/tasks.toml` (managed by [`rmap`](https://hex.pm/)). This file is rendered.

<!-- MILESTONES:BEGIN -->
### v0_1 — Standalone calc engine

- **target_version:** 0.1.0
- **status:** 🔄 active
- **hypothesis:** Proves the salvaged calculators run standalone (no Phoenix/Ecto/I-O) with their original test suites green, so the TradingDashboard rebuild can depend on DeltaCalc instead of reimplementing the math.
- **pinned tasks:** 8/8 done

### v0_2 — Dashboard calc primitives

- **target_version:** 0.2.0
- **status:** ⬜ pending
- **hypothesis:** Build the pure-Decimal calc primitives that TradingDashboard's future roadmap (hedging engine, risk monitoring, options strategy) specifies, so the dashboard consumes DeltaCalc.* rather than reimplementing the math. Source of truth: ~/_DATA/code/TradingDashboard/roadmap/phaseN.md specs.
- **pinned tasks:** 10/10 done

### v0_3 — Consumer decision primitives

- **target_version:** 0.3.0
- **status:** ⬜ pending
- **hypothesis:** The math the dashboard reaches for at the call-site: position PnL/ROE/breakeven net of fees+funding, net-delta rebalancing from exchange-supplied option deltas, portfolio-margin liquidation across netted positions, price-shock stress scenarios, fee modeling, and funding carry/break-even. Consumer-driven (delta_calc IS the consumer's math layer). Option pricing stays out — exchange supplies Greeks/IV; BS is a future separate lib.
- **pinned tasks:** 11/16 done
<!-- MILESTONES:END -->

## Phase 1 — Extraction

Port the pure `risk/` calculators and the pure hedging formulas out of the dead app, with
their original test suites green.

<!-- TASKS:BEGIN phase=1 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 1 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · 📝 Scaffold delta_calc library [D:1/B:5/U:5 → Eff:5.0?] 🎯 |
| Task 2 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · *DeltaCalc.Calc* · Port DeltaCalc.Calc (core engine) + its tests [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 3 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · *DeltaCalc.Presets* · Port DeltaCalc.Presets + tests [D:1/B:4/U:5 → Eff:4.5?] 🎯 |
| Task 4 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · *DeltaCalc.DCAPlanner* · Port DeltaCalc.DCAPlanner [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 5 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · *DeltaCalc.PositionCalculator* · Port DeltaCalc.PositionCalculator (decouple from LiveView assigns) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 6 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · *DeltaCalc.Hedging* · Extract DeltaCalc.Hedging (pure spot-hedging formulas) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 7 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · Backfill tests for PositionCalculator, DCAPlanner, Hedging [D:3/B:5/U:4 → Eff:1.5?] 🚀 |
| Task 8 | ✅ | 🎁 **calculators** · 🚀 **v0_1** · 📝 README + API docs + agent manifest + tighten doctor thresholds [D:1/B:3/U:4 → Eff:3.5?] 🎯 |
<!-- TASKS:END -->
