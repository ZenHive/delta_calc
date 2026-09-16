# Post-merge audit — `ff94236..1c7bcd4`

**Date:** 2026-09-16
**Range:** 3 commits (`ff94236` .. `1c7bcd4`), task 57 — *Assert inside tail-elided README
examples so no elision can hide a concrete value*
**Delivered by:** codex (`gpt-6-astra`) · run `run-1789542026034-87f2fef9`

## What was reviewed

| Commit | Subject |
|---|---|
| `ff94236` | roadmap: task 57 -> in_progress |
| `e532c6a` | harness: agent delivery — task 57 (`README.md`, `test/delta_calc/readme_examples_test.exs`) |
| `1c7bcd4` | roadmap: task 57 -> done |

Net product diff: **169 lines** — a subset-comparison path in the README-example extractor
(`parse_subset/1`, `assert_subset/3`, `concrete_count/1`), four new negative/positive test cases
for it, a three-way census, and three README examples moved to a caller-side rounding boundary.

Reviewed for: acceptance-criteria coverage, independently re-derived census, clause-ordering and
edge cases in the new comparison path, documented value correctness, dead code, debug leftovers,
CHANGELOG / CLAUDE.md / AGENTS.md coverage, roadmap render drift, and project conventions.

## Verdict on the landed work

**Sound.** All six acceptance criteria are met, and the judgement call AC 5 named (round in the
example vs. note the full-precision return) was resolved the same way task 56 resolved it, so the
README now carries one convention rather than two.

**Census re-derived independently** by re-implementing the extractor outside the test (Python,
against the current README): **52 examples — 38 asserted, 14 partial elisions, 0 whole-result
elisions**, and exactly **3** of the 14 elided examples carry an `:ok` tuple tag (README lines
228, 479, 489). That matches both pinned assertions, including the `44 + 3 = 47` concrete-position
count — and 44 is the number the previous audit measured independently as the unchecked positions
this task was filed to close. The 44 are now gated.

**The three rewritten values are correct roundings, not new values.** Each rounds the literal the
test previously asserted at full precision, so nothing about `lib/` behavior is implied to have
moved:

```
Calc.liquidation(3000, leff 2, mmr 0.005, :long)
  = 3000 x (1 - 1/2) / (1 - 0.005) = 1500 / 0.995 = 1507.537688...  -> round(2) 1507.54
PortfolioMargin.portfolio_liquidation_price        2512.562814...    -> round(2) 2512.56
Carry.breakeven_funding                           -0.000111111...    -> round(8) -0.00011111
```

**Comparison-path edge cases checked** and correct: clause order puts `%Decimal{}` ahead of the
`is_map/1` clause (a Decimal is a map, so the reverse would compare struct keys); a map without a
`@tail` key still compares its full key set exactly, so `%{a: ...}` against `%{a: 1, b: 2}` fails;
a short actual list (`[]` vs `[1, ...]`) falls through the cons clause to the concrete comparison
and fails on rendering; `assert_concrete/3` keeps `Decimal.equal?/2` value drift named separately
from the `inspect/1` rendering comparison, so scale-only drift still fails — AC 2 holds on the new
path. The `dialect_drift` guard was correctly widened from `asserted` to `examples`, so an elided
example can no longer document `Decimal.new(...)` form.

No reviewer rejections are recorded for this project, so nothing to re-adjudicate.

## Findings

### 1. CHANGELOG gap — **fixed** (minor)

Task 57 changed three documented return values on the library's front door and materially widened
the gate (47 previously-unchecked concrete positions now asserted), with no CHANGELOG trace. The
`Unreleased` section still described only task 55/56's version of the gate — a consumer reading it
would learn that README examples are executed, but not that a tail elision no longer exempts its
siblings.

Folded into the existing README-example bullet rather than opened as a new one, matching the
decision the previous audit made for task 56: it is the same story, and the file states it holds
"release-level history".

### 2. `CLAUDE.md` § "Documented output drift" understates the gate it documents — **fixed** (minor)

The section described the gate as "a pinned asserted/elided census so a new elision cannot quietly
opt an example out". After task 57 that is the *weaker* half of the guarantee: an elision now skips
only the `...` position itself, and the census is three-way plus a concrete-position count. This is
the text `AGENTS.md` is generated from — i.e. the contract the cross-family reviewer reads — so an
understated version of it is what lets the next diff argue a tail elision is a legitimate opt-out.
Rewritten to state the actual guarantee; `AGENTS.md` regenerated via `sync-agents-md.sh` and
`--check` re-confirmed.

### 3. README applied the rounding convention but not its rationale — **fixed** (nitpick)

Task 56's two examples carry `# Round at the caller's output boundary for display.`; task 57's
three did not — including `Calc.liquidation` at README line ~67, the **first** rounded example a
reader meets, so the idiom appeared unexplained on first contact and explained on third. Added the
same one-line comment to all three, so the five rounding examples now read identically. (Comment
lines are part of the example `code`, not the `#=>` continuation — the extractor's continuation
pattern requires `#` + 2 or more spaces — so this does not perturb the census. Re-verified: 38/14/0
and 47 unchanged.)

### 4. The new branch duplicated the diagnostic heredoc — **fixed** (nitpick)

`check_example/2` built the same three-line `README.md:line / Documented / Evaluated` heredoc in
both arms of the new `if elided?`, differing only in whether it inlined `render(actual)` or the
`actual_text` binding. Hoisted above the branch; the now single-use `expected_text` binding folded
into its assertion. `ex_dna --max-clones 0` did not flag it (below its clone threshold), which is
exactly why it is worth removing by hand before it is copied a third time.

### 5. The concrete-position census assertion had no failure message — **fixed** (nitpick)

`assert Enum.sum(...) == 47` sat directly beside a sibling census assertion that carries an
explanatory message. On failure it would have printed a bare `Assertion with == failed` with two
integers and no indication that a README elision had changed. Bound the sum and added a message
naming the observed count, matching the sibling.

### 6. `DeltaCalc.FundingProjection`'s doc examples were never executed — **fixed** (moderate)

`lib/delta_calc/funding_projection.ex:68,75` carries two `iex>` examples for
`project_payback_timeline/1` — the only `iex>` examples anywhere in `lib/` — and **no test module
registered them**: `test/delta_calc_test.exs` has `doctest DeltaCalc` and that is the entire
doctest surface. `ex_doc` ships those examples to consumers with no gate at all, which is precisely
the defect class tasks 55/56/57 spent three tasks closing for `README.md`.

Verified the examples are currently *correct* (both pass), so this was an exposure, not live drift.
Fixed by adding `doctest DeltaCalc.FundingProjection` to
`test/delta_calc/funding_projection_test.exs` — the suite goes 552 -> 554 (2 doctests).

### 7. Nothing prevents the *next* module's examples from landing ungated — **filed as task 58** (moderate)

Finding 6 is one instance; the structural hole is that doctest registration lives in a file the
authoring diff does not touch, so a per-task reviewer grading a new `## Examples` block cannot see
that it is unregistered. CLAUDE.md § "Review Blind Spots" prescribes the fix for exactly this shape
— a manifest-wide CI failure rather than a consumer discovery.

Filed as **task 58** — *"Fail CI when a lib module's `iex>` doc examples are not registered as
doctests"* (phase 3, `contract_hardening`, d3/b4/u3, `codex` / `gpt-6-astra`), scoped to gating
what exists (no mandate to write examples for the 24 modules that have none) and to live beside
the existing whole-surface invariants in the manifest-consistency test.

## Checks not flagged

- **Dead code / debug output / naming** — none. Every new private function is reachable:
  `parse_subset/1` from both the census and the elided branch, `concrete_count/1` from the census,
  `assert_subset/3` and `assert_concrete/3` from `check_example/2`. `@elision` and `@tail` are both
  used as module attributes and as pattern heads.
- **`lib/` behavior** — untouched in the range, as AC 6 required. (Finding 6 touches a test file
  only.)
- **Roadmap render drift** — `rmap render` was byte-identical before my own task-58 filing.
- **`reach.check --arch --smells`** — 2 findings (`presets.ex:41` redundant `Decimal.new`,
  `option_ladder.ex:420` repeated 4x map shape). Both pre-date this range, both in files it does
  not touch; exit 0. Not this range's debt, left alone.
- **Doc coverage** — `mix doctor` 100% doc / moduledoc / spec, 26 modules passed.

## Cold-build witness

Ran in this intentionally un-warmed worktree (no copied `deps`, `_build` or PLTs):

```
mix deps.get && mix check.dispatch
```

**Green.** A bare `mix check.dispatch` with no `deps` present exits **0** while printing
`** (Mix) Can't continue due to errors on dependencies` — worth knowing, since an audit that
trusted the exit code alone would record a green cold build having compiled nothing. After
`mix deps.get`: 552 tests passed pre-fix, **554** after (2 doctests added by finding 6), credo
`--strict` clean across 58 files, `ex_dna` 0 clones against a 0 budget, `mix format
--check-formatted` clean, `mix doctor` 100%, `sync-agents-md.sh --check` up to date. Compile
warnings in the output originate in dependency source (`vibe_kit`), none in `delta_calc`.

## Fixes applied in this audit commit

| File | Change |
|---|---|
| `CHANGELOG.md` | Extended the README-example bullet with task 57's outcome (finding 1) |
| `CLAUDE.md`, `AGENTS.md` | Restated the gate's actual guarantee; AGENTS.md regenerated (finding 2) |
| `README.md` | Rounding rationale on the three new `Decimal.round` examples (finding 3) |
| `test/delta_calc/readme_examples_test.exs` | Hoisted the duplicated diagnostic; message on the concrete-position census (findings 4, 5) |
| `test/delta_calc/funding_projection_test.exs` | `doctest DeltaCalc.FundingProjection` (finding 6) |
| `roadmap/tasks.toml`, `ROADMAP.md`, `roadmap/data.json` | Filed task 58 (finding 7) |
| `.audit/1c7bcd4.md` | This report |
