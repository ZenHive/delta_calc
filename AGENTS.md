# AGENTS.md

**DeltaCalc** — standalone, headless `Decimal` calculation engine for leveraged crypto trading
(position sizing, leverage, liquidation, DCA ladders, safety scoring, spot hedging). No Phoenix,
no Ecto, no I/O — pure value-in / value-out functions. Salvaged from the retired `TradingDashboard`
app; ported task-by-task per `roadmap/tasks.toml` (`rmap list`).

## Toolchain & check commands

- **Canonical gate:** `mix ci` — runs `format`, `compile --warnings-as-errors`, `test`,
  `credo --strict`, `dialyzer`, `ex_dna --max-clones 0`, `reach.check --arch --smells`.
  `mix precommit.full` is the equivalent pre-merge full pass.
- **`mix test.json` (`ex_unit_json`) emits JSON BY DESIGN.** A JSON object on stdout is a passing
  run, not a build failure. Parse `.summary.failed` / `.tests[]` for real failures; never flag the
  envelope. `{"...","result":"passed",...}` with `failed: 0` is green.
- **`mix dialyzer.json` (`dialyzer_json`) emits JSON BY DESIGN.** Same rule. If the JSON encoder
  can't serialize a warning shape, plain `mix dialyzer` is the authoritative check.
- **Coverage tiers:** ≥80% standard; **≥95% on `DeltaCalc.Calc` and `DeltaCalc.Hedging`** (money math).
- **Property tests:** ported `Calc` tests use `StreamData` — those are real tests, not flakes.

## Conventions

- **Pure `Decimal` only** — never floats for money/price/leverage.
- **Descripex `api()` on every public function**, placed before its `@doc`, written at port time
  (not backfit). `:value` param kind for money/price/leverage inputs.
- **decimal 3.x precision = 34 (was 28 under 2.x).** Reference values computed under the source
  app's decimal 2.x may differ at trailing digits — round at output boundaries, don't chase the
  default-context tail. See `CLAUDE.md` § Dependency Gotchas.
