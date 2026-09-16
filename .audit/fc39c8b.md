# Post-merge audit — `2cc5071..fc39c8b`

Date: 2026-09-16
Auditor: post-merge audit agent (Opus 5)
Range: `2cc5071057c4f8a6a4cd7ebc155f5e5637d8b00f..fc39c8bd5602b6995cceb7cb727cf1543930797f`

## Commits reviewed

| SHA | Subject |
|-----|---------|
| `2ac6a19` | roadmap: task 59 -> in_progress |
| `ae84ba9` | harness: agent delivery — task 59 (run `run-1789549228035-6cc00466`) |
| `fc39c8b` | roadmap: task 59 -> done (shipped `ae84ba901416`) |

Code surface in the range is a single file: `test/delta_calc/manifest_consistency_test.exs`
(+14 / -3). The other two commits are roadmap bookkeeping.

## What landed

Task 59 hardened manifest invariant 6 (the doctest-registration gate landed by task 58):

- Widened the gated module set from `Manifest.modules()` to
  `[DeltaCalc, Manifest | Manifest.modules()]` — the two documented lib modules that
  invariant 5 deliberately exempts from `@modules` registration, and therefore the only
  surfaces where an `iex>` example could sit with nothing executing it.
- Replaced the example detector `String.contains?(doc, "iex>")` with
  `Regex.match?(~r/^[\t ]*iex>/m, doc)`, so a doc that merely *mentions* the prompt in prose
  is not flagged. The two halves are coupled: widening the set without anchoring the detector
  would have gone red immediately on `DeltaCalc.Manifest`'s own moduledoc, which describes
  invariant 6 in prose.
- Added a direct negative-path test for the detector (fires on tab- and space-indented example
  lines and on a bare first-line example; does not fire on two prose mentions or on `""`).

Assessment: the delivery matches its acceptance criteria exactly, stays inside its declared
write-set, and changes no `lib/` behavior. The detector's error direction is safe in both the
before and after state (a prose mention could produce a spurious failure, never a silent pass),
so nothing that landed earlier was under-enforced. No dead code, no debug output, no leftover
markers, no convention breaks in the diff.

## Findings

Three instances of one class: **the gate's own prose documentation still describes task 58's
narrower rule.** Task 59's write-set was correctly limited to the test file, so the three places
that state invariant 6 in English were left describing a set and a detector that no longer match
the code. This is the documented-output-drift class `CLAUDE.md` § "Review Blind Spots" names —
a per-task reviewer grading one diff against one task has no reason to read them.

| # | File | Stale claim | Severity |
|---|------|-------------|----------|
| 1 | `lib/delta_calc/manifest.ex:15` | "Every **registered** module whose compiled docs **contain** `iex>` examples" — wrong on both the set and the match. Shipped in the hex package as `DeltaCalc.Manifest`'s moduledoc, i.e. the consumer-facing statement of the rule. | minor |
| 2 | `CLAUDE.md:104` (→ `AGENTS.md:1183`) | Same wording. This is the text the cross-family reviewer reads, so a future diff could be graded against the superseded rule. | minor |
| 3 | `CHANGELOG.md:9` (Unreleased) | "when a **registered** module's `@doc`/`@moduledoc` carries an `iex>` example" — the entry is still unreleased, so it is the release-note text for both task 58 and 59. | minor |

Nothing above is a correctness defect; all three are the same one-line rule stated in three
places and updated in none.

## Fixes applied

1. `lib/delta_calc/manifest.ex` — invariant 6 now states the widened set (registered modules plus
   `DeltaCalc` and `DeltaCalc.Manifest`, the two exemptions) and the anchored detector, with an
   explicit note that the sentence's own prose mention is not an example. Kept the prompt
   mid-line so the moduledoc stays outside the gate it describes — verified by `mix ci`.
2. `CLAUDE.md` — same correction in the "Cross-module global invariants" blind-spot section;
   `AGENTS.md` regenerated via `sync-agents-md.sh` (`--check` reports up to date).
3. `CHANGELOG.md` — the Unreleased invariant-6 bullet now covers task 59's widening and the
   line-anchored detector, rather than silently describing only task 58's half.

Doc-only; no behavior change.

## Discoveries filed

**Task 60** — *Derive the manifest gate's module set from the filesystem instead of two
hand-maintained carve-outs* (phase 3, `contract_hardening`, D2/B3/U2, codex / gpt-6-astra).

Task 59's fix is correct for the tree as it stands but substitutes a literal carve-out list for a
derived set — the shape task 58's own CHANGELOG entry claims the gate avoids ("never from a
hand-maintained allowlist"). Two latent holes survive, both failing *open*:

- `documented_modules_from_lib/0` (`manifest_consistency_test.exs:297`) uses a non-recursive
  `File.ls!` on `lib/delta_calc/`. `lib/` is flat today, so nothing is missed — but the first
  module placed in a subdirectory is invisible to invariant 5 and transitively to invariant 6.
- A documented module added at `lib/*.ex` alongside `delta_calc.ex` is outside the scanned
  directory *and* absent from the literal, so neither invariant sees it.

Filed as the class statement rather than a third instance (DD-8 sibling check against task 59
recorded in the task body): deriving the set removes the carve-out list as a thing that must be
maintained in step with `lib/`.

## Reviewer-quality note

No reviewer rejections are recorded for this project, and none apply to this range. The task 59
verdict (approved, verified by `cursor`, ref `harness-run:run-1789549228035-6cc00466`) matches
what actually landed.

## Cold-build witness

Worktree was un-warmed (no `deps`, `_build`, or PLTs). `mix deps.get` then `mix check.dispatch`
from cold: **pass** (exit 0) — 558 tests / 2 doctests / 31 properties, credo `--strict` clean,
`ex_dna --max-clones 0` clean.

After the doc fixes, the full `mix ci` (which adds dialyzer and `reach.check --arch --smells`)
also passes, exit 0. `reach.check` prints two pre-existing non-failing smells
(`presets.ex:41` duplicate `Decimal.new`, four repeated map shapes in `option_ladder.ex`) that
predate this range and are not part of it.

## Verdict

Range is sound; the delivery is clean and correctly scoped. Three doc-drift instances of one
rule, all fixed here. One class-level hardening opportunity filed as task 60.
