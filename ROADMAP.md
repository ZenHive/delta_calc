# DeltaCalc Roadmap

Salvage the calculation engine from the retired **TradingDashboard** app into a standalone,
headless library so the rebuild depends on `DeltaCalc` instead of reimplementing the math.

Source of truth: `roadmap/tasks.toml` (managed by [`rmap`](https://hex.pm/)). This file is rendered.

<!-- MILESTONES:BEGIN -->
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

### v0_3 — Consumer decision primitives

- **target_version:** 0.3.0
- **status:** ✅ done
- **hypothesis:** Proves TradingDashboard can consume DeltaCalc as the unit-consistent, independently checked source for everyday leveraged-trading decisions without compensating for hidden venue constants or ambiguous contracts.
- **pinned tasks:** 25/25 done

### v0_4 — Base-numeraire covered-call math

- **target_version:** 0.3.0
- **status:** ✅ done
- **hypothesis:** Proves an ETH-numeraire covered-call consumer can calculate inverse exposure and settlement capacity from explicit provider facts while keeping coverage, risk targets, and approval policy separate.
- **pinned tasks:** 1/1 done
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
> 34 tasks. See [CHANGELOG.md](CHANGELOG.md#phase-3-consumer-decision-math).
<!-- TASKS:END -->
