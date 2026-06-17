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

`roadmap/tasks.toml` is canonical (`rmap` renders `ROADMAP.md` + `roadmap/data.json`). Phase 1
"Extraction", milestone `v0_1`. `rmap ready` shows the dispatchable set; tasks 2/3/6 are layer-0.

## Quality Gate

`mix ci` (format, compile `--warnings-as-errors`, test, `credo --strict`, dialyzer,
`ex_dna --max-clones 0`, `reach.check --arch --smells`). Coverage tiers: ≥80% standard,
≥95% on `Calc`/`Hedging` money math.

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
