# CLAUDE.md

Guidance for Claude Code working in this repo.

@~/.claude/includes/critical-rules.md
@~/.claude/includes/harness-workflow.md
@~/.claude/includes/worktree-workflow.md

<!-- Setup-window imports — drop once the library is fully ported; the elixir:* /
     elixir:agent-economy skills cover these on-demand afterward. -->
@~/.claude/includes/elixir-setup.md
@~/.claude/includes/agent-economy.md

- **Reviewer note**: `mix test.json` (`ex_unit_json`) and `mix dialyzer.json` (`dialyzer_json`) emit JSON **by design** — parse for real failures, never flag the envelope. Canonical gate is `mix ci` / `mix precommit.full`. See `AGENTS.md` § Toolchain & check commands.

## Project Overview

**DeltaCalc** — a standalone, **headless** `Decimal` calculation engine for leveraged crypto
trading: position sizing, effective leverage, liquidation price, DCA ladders, safety scoring,
and spot hedging. Salvaged from the retired `TradingDashboard` app so a rebuild depends on this
library instead of reimplementing the math. **No Phoenix, no Ecto, no I/O** — pure value-in /
value-out functions.

### Scope Boundary — delta_calc Owns Reconcilable Money, zen_quant Owns Estimates

`zen_quant` (`~/_DATA/code/zen_quant`, on Hex) is a sibling analytics library with no
dependency relationship in either direction, and the two are split **by numeric regime, not
by topic**:

- **delta_calc owns anything that must reconcile against an exchange balance** — money,
  margin, fees, hedge sizes, lot-quantized order quantities. `Decimal`, because a number
  the operator compares against a venue statement may not carry float error.
- **zen_quant owns anything that is an estimate** — option pricing, implied vol, greeks,
  skew, vol estimators, risk ratios, orderflow, signals, sizing *fractions*. Float.

**The split is forced, not stylistic.** `Decimal` has no `exp`, `ln`, or `erf` — so
Black-Scholes, IV solving and the volatility estimators **cannot** be implemented here, and
an attempt to add them means either a wrong answer or a float sneaking into a `Decimal`
library. Send that work to zen_quant instead.

**Before adding a function here, ask which side of that line it falls on.** The two overlap
*conceptually* in about a dozen places (funding APR, basis, PnL, concentration, liquidation
distance, stress tests, max loss, position sizing) — that overlap is intended, because each
side answers it in its own regime. Three public names already exist in both by design:
`max_loss`, `realized_pnl`, `unrealized_pnl`.

One overlap resolves into a pipeline rather than a duplicate: `ZenQuant.Sizing.kelly`
answers *which fraction*, `DeltaCalc.PositionCalculator.calculate_position` answers *which
exact quantized size*. Prefer that shape over reimplementing either end.

## Architecture & Conventions

- **Pure `Decimal` only** — never floats for money/price/leverage.
- **Module surface** (ported task-by-task, see roadmap): `DeltaCalc.Calc` (core engine),
  `DeltaCalc.Presets`, `DeltaCalc.DCAPlanner`, `DeltaCalc.PositionCalculator`, `DeltaCalc.Hedging`.
- **Agent surface (Descripex):** annotate **every** public function with `api(name, desc, opts)`
  immediately before its `@doc`, **at port time** — not as a backfit. `:value` param kind for
  money/price/leverage inputs. `DeltaCalc.Manifest` + `Descripex.MCP.tools/1` aggregate the surface.
- **Source of truth for ports:** the retired app at `~/_DATA/code/TradingDashboard`
  (`lib/trading_dashboard/risk/*.ex`, `portfolio.ex` + `portfolio/snapshot.ex` hedging formulas,
  `test/trading_dashboard/risk/*.exs`).

## Roadmap

`roadmap/tasks.toml` is canonical (`rmap` renders `ROADMAP.md` + `roadmap/data.json`). Phases 1–2
and milestones `v0_1`–`v0_2` are complete. Phase 3 and milestone `v0_3` are the active focus.
Use `rmap ready` for the dispatchable set and its declared write-sets before parallel dispatch.

## Quality Gate

`mix ci` (format, compile `--warnings-as-errors`, test, `credo --strict`, dialyzer,
`ex_dna --max-clones 0`, `reach.check --arch --smells`). Coverage tiers: ≥80% standard,
≥95% on `Calc`/`Hedging` money math.

## Review Blind Spots — Encode What Per-Task Review Can't See

The harness reviewer grades **one diff against one task**: mechanical checks (credo/dialyzer/
coverage), the task's stated acceptance criteria, and internal consistency. It cannot see two
things, and real correctness bugs landed clean through both gaps (tasks 24/25/26):

- **Domain ground truth.** A hardcoded venue constant (`@funding_periods_per_day 3`, an 8h-interval
  assumption that overstates Deribit's hourly funding ~8×) is internally consistent, fully tested,
  and passes every check — because the golden test was computed *with* the wrong constant, so
  coverage ratifies the bug instead of catching it. The reviewer has no signal the value is wrong;
  that knowledge lives in the consumer's head. **Fix: push domain invariants into acceptance
  criteria** — e.g. "no venue-specific constants; funding cadence / fee tier / interval is a
  caller-supplied `:value` param." Then the reviewer *can* reject the hardcode.
- **Cross-module global invariants.** Write-set-disjoint parallel dispatch means two modules can
  each define `project_payback_timeline` in separate worktrees and neither review sees the other —
  the name collision only surfaces at the consumer. **Fix: the manifest-consistency test**
  (`mix ci`) asserts public name+arity uniqueness across all registered modules, full module
  registration in `DeltaCalc.Manifest`, and the `:hints`-present invariant. Turn global invariants
  into CI failures, not consumer discoveries.

Rule of thumb: if a defect can only be caught by knowing the *domain* or seeing the *whole surface*,
no per-task reviewer will catch it — encode it as an acceptance criterion or a manifest-wide test.

## Domain Invariants — The Load-Bearing Truths a Per-Task Reviewer Can't See

These are the cross-cutting domain rules that every module must honor and that no single-diff
review can verify. They are **enforced as executable assertions** in
`test/delta_calc/domain_invariants_test.exs` (run by `mix ci`), computed independently of the
formulas under test — never re-asserting current output. State them here so the cross-family
reviewer (which reads `AGENTS.md`, generated from this file) can reject a diff that violates one.
When a new invariant is discovered, add it both here and as a test; the test is the gate, this list
is the rationale.

- **Funding rate is a fraction, everywhere.** Every funding-rate `:value` input across the surface
  is a decimal fraction (`0.0001` = 0.01%), matching `Funding`/`Carry`/`Hedging` — the canonical
  convention. No module may treat the same numeric rate as a percent and divide by 100 internally.
  The same rate fed to two modules must give dimensionally consistent results, not a silent 100x.
- **Raw→daily scales by ×periods, in one direction.** `daily = raw_per_period × periods_per_day`,
  so a raw threshold expressed on a daily basis is **larger**, not smaller. Any raw→daily
  conversion (arbitrage threshold, `min_delta` normalization) multiplies by periods; a `÷periods`
  on this conversion is the bug.
- **No baked-in venue constants in generic math.** Funding cadence, MMR tier schedules, fee tiers,
  and kill-switch thresholds are caller-supplied `:value` params. Any default left in place is
  documented as a convention and is overridable — proven by a test feeding a non-default value.
- **Goldens are independently sourced.** High-risk formula fixtures (liquidation, sizing, DCA, fees,
  funding) assert against values computed *outside* the code under test — hand-computed, from a
  spec, or external reference — with documented provenance, compared as `Decimal` with explicit
  tolerances (never `to_float`). A golden derived from the same formula proves consistency, not
  correctness, and ratifies any constant error baked into the formula.

**Pending invariants** (target post-fix state for an open roadmap task) are tagged
`@tag :domain_pending` and excluded from the default run so the harness bundle stays green; they are
real red assertions, not `assert true`. Run them with `mix test --include domain_pending` to watch
each go green as its task lands — the fixing task's acceptance criteria include removing its tag.
Each carries a `TODO(Task N)` inside its `flunk/1` message, so a pending assertion names its owning
roadmap task at the point it fails. The task ID is required — a bare `TODO` is not enough to place
the work. Credo's `TagTODO` stays enabled and does not see these: it scans comments and docs, not
string literals, so the tracked markers cost nothing while real untracked TODOs in comments still
get flagged.

## AGENTS.md is generated — regenerate after editing CLAUDE.md

`AGENTS.md` is **not** hand-authored: it's the Codex-facing view of this file, produced by
inlining every `@`-import from `CLAUDE.md` (Codex doesn't inherit our Claude Code hooks, so
AGENTS.md carries the rules they'd enforce). After any `CLAUDE.md` edit, regenerate:

```sh
~/.claude/plugins/marketplaces/zenhive/scripts/sync-agents-md.sh          # write
~/.claude/plugins/marketplaces/zenhive/scripts/sync-agents-md.sh --check  # freshness gate (CI)
```

Never edit `AGENTS.md` directly — it's overwritten. Both files are committed; `--check` exits
non-zero when AGENTS.md has drifted (including drift in transitive `@`-imports).

## Tidewave

This library runs Tidewave via a **standalone Bandit** endpoint (no Phoenix). Start it with
`mix tidewave` (port **4024**); the `.mcp.json` `tidewave` server points there. `harness` MCP is
the harness dashboard at `:4018` for roadmap ingest/dispatch.

## Dependency Gotchas

### decimal 3.x — default context precision changed (28 → 34)

Bumped `decimal` `~> 2.0` → `~> 3.0` (2.4.1 → 3.1.1) on 2026-06-17 (forced by `doctor` 0.23.0, which requires `decimal ~> 3.1`). Breaking changes vs 2.x:

- **Default `Decimal.Context` precision is now 34 (decimal128), was 28.** Division and other precision-bound ops carry MORE significant digits by default. When porting calc logic from the source project (whose reference values were computed under 2.x), **expect division/rounding results to differ at the trailing digits** — golden/snapshot values captured under decimal 2.x may not match. Set an explicit context or `Decimal.round/2,3` at output boundaries rather than relying on the default precision.
- `Decimal.parse/1` and `Decimal.cast/1` now reject inputs with >34 digits or absolute exponent >6_144. Realistic trading figures never hit this; pass `max_digits: :infinity` / `max_exponent: :infinity` to the `/2` arity if a genuine giant value is ever needed.
- `Decimal.to_string/2,3` raises on output >6_178 digit chars (Inspect/String.Chars/JSON.Encoder bypass it). Irrelevant to this domain.

Source: https://github.com/ericmj/decimal/blob/main/CHANGELOG.md
