# DeltaCalc Roadmap

Salvage the calculation engine from the retired **TradingDashboard** app into a standalone,
headless library so the rebuild depends on `DeltaCalc` instead of reimplementing the math.

Source of truth: `roadmap/tasks.toml` (managed by [`rmap`](https://hex.pm/)). This file is rendered.

<!-- MILESTONES:BEGIN -->
### v0_3 — Consumer decision primitives

- **target_version:** 0.3.0
- **status:** 🔄 active
- **hypothesis:** Proves TradingDashboard can consume DeltaCalc as the unit-consistent, independently checked source for everyday leveraged-trading decisions without compensating for hidden venue constants or ambiguous contracts.
- **pinned tasks:** 16/25 done

### v0_4 — Base-numeraire covered-call math

- **target_version:** 0.4.0
- **status:** ⬜ pending
- **hypothesis:** Proves an ETH-numeraire covered-call consumer can calculate inverse exposure and settlement capacity from explicit provider facts while keeping coverage, risk targets, and approval policy separate.
- **pinned tasks:** 0/1 done

### v0_1 — Standalone calc engine

- **target_version:** 0.1.0
- **status:** ✅ done
- **hypothesis:** Proves the salvaged calculators run standalone (no Phoenix/Ecto/I-O) with their original test suites green, so the TradingDashboard rebuild can depend on DeltaCalc instead of reimplementing the math.
- **pinned tasks:** 8/8 done

### v0_2 — Dashboard calc primitives

- **target_version:** 0.2.0
- **status:** ✅ done
- **hypothesis:** Proves TradingDashboard's planned funding, account-risk, options, and margin workflows can consume standalone DeltaCalc primitives instead of embedding formulas. Source of truth: ~/_DATA/code/TradingDashboard/roadmap/phaseN.md specs.
- **pinned tasks:** 10/10 done
<!-- MILESTONES:END -->

## Phase 1 — Extraction

Port the pure `risk/` calculators and the pure hedging formulas out of the dead app, with
their original test suites green.

<!-- TASKS:BEGIN phase=1 -->
> 8 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-1-extraction).
<!-- TASKS:END -->

## Phase 2 — Calc primitives

Build the standalone Decimal primitives consumed by the dashboard without adding runtime or UI concerns.

<!-- TASKS:BEGIN phase=2 -->
> 10 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-2-calc-primitives).
<!-- TASKS:END -->

## Phase 3 — Consumer decision math

Complete the cross-module correctness work and the pure decision primitives used at trading call sites.

<!-- TASKS:BEGIN phase=3 -->
| Task | Status | Notes |
|------|--------|-------|
| Task 17 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · *DeltaCalc.PnL* · Build DeltaCalc.PnL (position PnL, ROE, breakeven net of fees + funding) [D:2/B:4/U:5 → Eff:2.25?] 🎯 |
| Task 18 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · *DeltaCalc.DeltaNeutral* · Build DeltaCalc.DeltaNeutral (net delta + rebalance from exchange-supplied deltas) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 19 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · *DeltaCalc.PortfolioMargin* · Build DeltaCalc.PortfolioMargin (combined maintenance margin + netted liquidation) [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 20 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · *DeltaCalc.StressScenario* · Build DeltaCalc.StressScenario (price-shock cascade across the book) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 21 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · *DeltaCalc.Fees* · Build DeltaCalc.Fees (effective entry/exit, roundtrip cost, funding-adjusted breakeven) [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 22 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · *DeltaCalc.Carry* · Build DeltaCalc.Carry (basis yield + break-even funding for hedge profitability) [D:2/B:3/U:3 → Eff:1.5?] 🚀 |
| Task 23 | ✅ | 🎁 **consumer_math** · 🚀 **v0_3** · Register v0_3 modules in DeltaCalc.Manifest + README [D:1/B:3/U:4 → Eff:3.5?] 🎯 |
| Task 26 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · *DeltaCalc.MarginBridge* · Fix DeltaCalc.MarginBridge hardcoded funding cadence (3/day overstates Deribit ~8x) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 27 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · *DeltaCalc.Manifest* · Manifest-consistency test: unique public names + full module registration across DeltaCalc.Manifest [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 28 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · *DeltaCalc.Funding* · Fix Funding.compare_single_symbol hardcoded x3 cadence (same Deribit bug as task 26) [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 29 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · *DeltaCalc.Carry* · Fix Carry.annualized_basis misnomer: returns raw basis, not annualized (+ basis_yield stock/flow mismatch) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 30 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · *DeltaCalc.OptionsRisk* · OptionsRisk: thread periods_per_day to MarginBridge (cadence locked to 3/day) + rename hardcoded total_90d field [D:2/B:3/U:4 → Eff:1.75?] 🚀 |
| Task 31 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · Fix Calc.compare_dca_safety side-blind PnL (multi_leg_position computes short as long) [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 32 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · Fix StressScenario.cascade equity reset: realized losses of liquidated legs are discarded [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 33 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · Add stream_data property-test layer encoding quant-audit invariants (anti-ratification guard) [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 34 | ✅ | 🎁 **contract_hardening** · 🚀 **v0_3** · Differential test: delta_calc liquidation + funding-cost vs recorded ccxt venue spec (offline fixtures) [D:4/B:4/U:4 → Eff:1.0?] 📋 |
| Task 35 | ✅ | 🎁 **contract_hardening** · Fix Funding.compare_funding_rates cross-cadence ranking: max/min and arbitrage from raw rates, annualized at per-venue cadence [D:4/B:6/U:6 → Eff:1.5?] 🚀 |
| Task 36 | ✅ | 🎁 **contract_hardening** · Reconcile Funding :delta units across scalar vs venue-map cadence paths (find_arbitrage_opportunities min_delta scale) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 37 | ✅ | 🎁 **contract_hardening** · Fix inverted min_delta raw→daily scaling in Funding.find_arbitrage_opportunities (divide vs multiply) [D:3/B:5/U:5 → Eff:1.67?] 🚀 |
| Task 38 | 🔄 | 🎁 **contract_hardening** · 🚀 **v0_3** · 🐛 Standardize funding-rate unit (fraction) across all DeltaCalc modules [D:4/B:8/U:7 → Eff:1.88] 🚀 |
| Task 39 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · 🐛 Centralize Decimal coercion and eliminate silent input fallbacks [D:7/B:8/U:8 → Eff:1.14] 📋 |
| Task 40 | ✅ | 🎁 **contract_hardening** · Manifest consistency test must cover unannotated public functions [D:2/B:6/U:6 → Eff:3.0?] 🎯 |
| Task 41 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · 🐛 Remove baked-in venue risk constants from generic margin/liquidation math [D:5/B:8/U:7 → Eff:1.5] 🚀 |
| Task 42 | ⬜ | 🎁 **consumer_math** · 🚀 **v0_3** · Expose side-aware public multi_leg_position (shorts) [D:3/B:6/U:6 → Eff:2.0] 🎯 |
| Task 43 | ✅ | 🎁 **contract_hardening** · Fix PortfolioMargin netted mark price for offsetting legs [D:4/B:7/U:6 → Eff:1.62?] 🚀 |
| Task 44 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · 🐛 Make DCA and position-sizing inputs behaviorally truthful [D:5/B:6/U:6 → Eff:1.2] 📋 |
| Task 45 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · Replace formula-derived golden values with independent fixtures [D:7/B:9/U:8 → Eff:1.21] 📋 |
| Task 46 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · Advertise exact Decimal inputs as canonical JSON strings in Descripex [D:6/B:7/U:7 → Eff:1.17] 📋 |
| Task 47 | ✅ | 🎁 **contract_hardening** · Move presentation strings out of pure-calc results [D:2/B:5/U:5 → Eff:2.5?] 🎯 |
| Task 48 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · Move rounding to explicit caller-controlled output boundaries [D:7/B:6/U:4 → Eff:0.71] ⚠️ |
| Task 49 | ✅ | 🎁 **contract_hardening** · Disambiguate zero-as-sentinel vs legitimate zero in Calc returns [D:3/B:4/U:4 → Eff:1.33?] 📋 |
| Task 50 | ✅ | 🎁 **contract_hardening** · Fix per-position liquidated? semantics in StressScenario.apply_shock [D:2/B:4/U:4 → Eff:2.0?] 🎯 |
| Task 51 | ⬜ | 🎁 **contract_hardening** · 🚀 **v0_3** · Split Calc god-module along cohesion seams [D:7/B:5/U:4 → Eff:0.64] ⚠️ |
| Task 53 | ⬜ | 🎁 **consumer_math** · 🚀 **v0_4** · Add base-numeraire inverse exposure and covered-call coverage math [D:6/B:8/U:7 → Eff:1.25] 📋 |
<!-- TASKS:END -->
