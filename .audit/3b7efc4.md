---
sha: 3b7efc4003f53ddf18012251de7919ded3138533
short_sha: 3b7efc4
audited_at: 2026-06-17
auditor_model: claude-opus-4-8
verdict: clean
codex_status: dual-reviewer
audited_by: audit-review v1
---

# Audit: task 34 — ccxt differential test (offline fixtures)

**Original commit:** `3b7efc4` (+ its `roadmap: ... -> done` status flip — expected harness maintenance).
**Files touched:** test/delta_calc/ccxt_differential_test.exs,test/support/ccxt_fixtures/README.md test/support/ccxt_fixtures/funding_and_liquidation.json

## Findings

Differential test vs recorded Binance/Deribit/Hyperliquid funding (8h/8h/1h) + Binance liquidation. Verified venue costs (-12.033, 18.00, 3.058). Includes a refute proving the cadence fix changed behavior vs old periods_per_day:3. README documents offline-only + refresh. The in-bundle diff is clean; a LATER commit (74420d1) degraded the liquidation assertion to always-pass — audited in .audit/74420d1.md. This commit: clean.

## Codex second-opinion

Status: dual-reviewer (job task-mqi6uyzg-5f75qs, consolidated bundle pass). Codex independently reviewed this commit and reported clean. Codex could not run `mix` (sandbox lacked deps); reviewed from diffs + current source.

## Auto-applied fixes

None — commit is clean.
