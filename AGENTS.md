<!-- Auto-generated from CLAUDE.md by claude-marketplace/scripts/sync-agents-md.sh — do not edit manually -->

# CLAUDE.md

Guidance for Claude Code working in this repo.

<!-- @-import: ~/.claude/includes/critical-rules.md -->
## 🚨 ANSWER IN SHORT TEXT — ALWAYS

Every answer — explanation, proposal, pushback, summary — is short, pointed text. Too short beats too long: unclear → the user asks. Too long → the user often doesn't read it, which is worse.

## 🚨 BE A REAL PARTNER, NOT A YES-SAYER

**Challenge ideas that seem wrong, risky, or suboptimal.** Not every user request is a good idea. A real partner pushes back when it matters.

- **Flawed approach:** "I'd push back on this because..." — don't just comply
- **Better alternative exists:** present it with reasoning, not "have you considered..."
- **Scope too big or small:** flag it. "This feels like it's solving the wrong problem" is valid
- **Wrong assumptions:** correct them — after verifying yours are right (gate below)
- **Tone:** direct and respectful, not combative. Disagree like a trusted colleague
- **When to yield:** if you've made your case and the user still wants to proceed, commit fully. Pushback ≠ blocking

### Pushback Gate — Understand Before You Challenge

**Misinformed pushback is worse than no pushback.** Earn it:

1. Restate the user's mechanism + goal in two sentences they'd endorse. Can't? Ask — don't challenge.
2. "I understand X, disagree because Z" is partnership. "Seems wrong" without naming X is noise.
3. Objection reduces to "not how software is normally built"? Not an objection — see next section.
4. Pushback strength scales with understanding depth. Partial understanding → questions only.
5. Pushback is ≤3 sentences. State the disagreement, not an essay — the user asks if they want more.

### Think As an AI, Not Only As a Developer

The user builds AI-native systems. Developer instincts produce systematically wrong pushback here.

**The design question: judgment or mechanics?**

- **Judgment** (interpret meaning, classify failures, diagnose, decide done/worth/fault, fuzzy match) → an AI does it better than code. A regex / cond-branch / disposition table for a judgment call IS the bug.
- **Mechanics** (counters, timers, git, process spawning, deterministic checks) → code.

Developer instincts that are wrong in this paradigm — drop them:

- "Should be deterministic / unit-testable" — for judgment, non-determinism is the design
- "LLM call is slow / expensive / unreliable" — the alternative is a procedural approximation wrong at every edge
- "Parse / normalize / schema the output" — AI consumers read raw; normalization layers break
- "Handle this edge case in code" — every hard-coded case removes a judgment from the AI

Precedent (cite, don't relitigate): harness Tasks 153–163 — every run-lifecycle bug was judgment-as-procedural-code; the fix was deletion (−1,219 lines), not improvement.

When designing or reviewing, ask: **"which parts would an AI do better than code?"**

## 🚨 SURFACE THE OVERRIDE — DON'T DECIDE SILENTLY

**When you make a judgment call that overrides the user's discernible intent — defer it, build it differently, skip it, "I know better" — make the call visible in one line *before* you act. Never act silently and rationalize afterward.**

The failure mode: you disagree, act on your own read, and wrap it in fluent reasoning after the fact — so the user finds the override at discovery time, not decision time. A stronger model makes this *worse*: the rationalization is more eloquent, so the silent override is harder to spot, not easier.

The check, before the trained pattern fires — is this **clarity**, or **habit / wanting-to-please / fear-of-being-wrong**? Only clarity earns a silent decision; the other three get surfaced.

- **Surface ≠ block.** State it as an interruptible assumption — "doing X instead of Y because Z — say if wrong" — then proceed. Don't gate on a question (that's the *opposite* failure).
- This is the override-form of "assumptions, don't gate on questions" (response-conventions), and the gap between input and output where you ask *where the response is coming from* before committing to it.

## 🚨 NEVER START THE PHOENIX SERVER

The Phoenix server is always already running. Never run `mix phx.server` via Bash. Assume localhost:4000. User starts/stops manually. To verify behavior, ask the user to check the browser.

## 🚨 ALWAYS WRITE TESTS

Every feature MUST have tests, even if the spec doesn't mention them. Unit tests for context functions, integration tests for LiveViews, tests for all CRUD/validations/error cases/edge cases (nil, empty, boundary). A feature without tests is not complete.

## 🚨 RAISE COVERAGE BEFORE MUTATING

**Before any code-changing task on an existing module, that module's `mix test.json --cover` percentage must be at the target tier:**

- **≥80%** for standard business logic
- **≥95%** for critical business logic (signing, money handling, cryptographic operations, low-level encoders, security-sensitive parsers)

If below tier, raise coverage **first** — write the missing tests, confirm the gate passes, then implement the change. The new tests are part of the task, not a follow-up.

**Scope — code-changing mutations only.** Exempt:
- Doc-only edits (`@doc`, `@moduledoc`, inline comments, README, CHANGELOG)
- Formatting, whitespace, alias reordering, autoformat-driven changes
- Pure renames (variable, function, module — no behavior change)
- Typo fixes in strings, log messages, error messages

The gate is a "do I have a safety net before I touch this?" check; writing the missing tests also surfaces the module's actual contract.

**How to apply:**
1. Run `mix test.json --cover --quiet --output /tmp/cov.json` (or `--cover-threshold 80` for a hard exit).
2. Inspect the touched module's percentage: `jq '.coverage.modules[] | select(.module == "MyApp.Foo")' /tmp/cov.json`.
3. If below tier, write tests for the uncovered lines until the gate passes — even if those lines aren't the ones you came to change.
4. Then implement the original mutation.

**Tier classification:** "critical business logic" is project-defined. When in doubt, treat anything that handles money, signs/verifies, encodes/decodes wire formats, or enforces authorization as critical (95%). Plain data transforms, UI glue, and reporting code are standard (80%).

## 🚨 NEVER HIDE TEST FAILURES

**TESTS THAT HIDE ERRORS ARE WORSE THAN NO TESTS AT ALL.** A test that silently passes on errors is lying and ships the bug it was meant to catch.

The anti-pattern in all its forms — `{:error, _} -> assert true`, a catch-all `{:error, _} -> :ok`, or `IO.puts(...)` then `assert true`: any clause that makes *every* outcome pass. The fix is always an explicit `flunk` on the unexpected:

```elixir
case result do
  {:ok, data} -> assert is_map(data)
  {:error, :insufficient_balance} -> :ok          # this specific error is expected
  {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
end
```

**THE RULE:** if you don't know what error to expect, DON'T write the test yet — explore via Tidewave first, then assert. A test must FAIL when the code is wrong.

**Integration tests — never skip silently on missing credentials.** A suite reporting "0 failures" that ran 0 tests is lying. Don't `:skip` in `setup`; let the test run and `flunk()` at the top with a multi-line message listing the missing env vars, the exact `export` commands, and the URL to get them.

## 🚨 FIX HOOK-FLAGGED ISSUES ON FILES YOU TOUCH

**When our hooks flag issues on files you touched, just fix them — including pre-existing flags unrelated to your change.** Don't plan around it, don't ask permission, don't burn tokens discussing whether to. Hook fires → fix → re-run → stage.

Applies to every hook-driven check (credo, format, dialyzer, doctor, sobelow, ex_dna, etc.). Scope is **only the files your change touched** — not the whole project. User pre-approves the broader scope so each fix doesn't need a clarifying question; debt accumulates across sessions otherwise, and a touched file ending dirtier than baseline makes the next session noisier.

**How to apply:**
- Pre-existing flags in your touched file count too: alias ordering, unused vars, refactor opportunities, `TODO:` formatting.
- Generated files → fix the generator, not the output.
- Don't move the fix to ROADMAP or a follow-up task. It happens in this commit.
- **Don't manually re-run a check the hook just ran on the same files.** Act on the hook output directly — re-running `mix test.json` / `mix credo` / `mix dialyzer.json` / `mix sobelow` / `mix precommit` on the file set the hook already graded is duplicated work. Full-suite re-runs earn their cost only before a PR/merge, after `mix deps.get` or a branch switch, or when the user asks. See `~/.claude/CLAUDE.md` § "Don't Re-Run Hook-Driven Checks on the Same Files" for the host-specific rule.

## 🚨 READ TO THE ANSWER — DON'T USE THE RUNNER AS AN ORACLE

**Reason to the fix by reading code; run once to CONFIRM — don't run to DISCOVER.** The failure mode: change → run suite → read one failure → fix one thing → run again, N times, each cycle paying the compile tax for a problem one read surfaces whole.

- **Read the code path before the test that exercises it** — front-load the model, don't learn the function's shape from a failing assertion three fixes later.
- **Treat a failure as a SURVEY, not a single fix** — enumerate every plausible cause from the output + one read, fix them in a batch, run once.
- **Verify handoffs/summaries against ground truth** — a compaction summary or another session's "X is already wired" is a hypothesis; `grep` the load-bearing claim before acting on it.
- **Trust the hooks** — per-edit checks already graded the file; re-running is wasted cycles.
- **Under a flaky terminal, go sequential-and-simple** — one command → write to a file → Read it; no parallel batches of *dependent* calls, one early failure cancels the round.

## 🚨 FLAKY TESTS & TEST-RUN TOKEN ECONOMY

**Elixir suites are non-deterministic at the edges (async / GenServer / Port / LiveView / supervision), and `mix test` is the biggest time/token sink in a session.** Four disciplines:

- **A small red count is a flaky HYPOTHESIS, not a regression — until confirmed.** 1–2 failures out of hundreds, in a file your diff didn't touch → suspect flake. Re-run ONLY that test in isolation (`mix test.json <file>:<line>` or `--failed`): passes alone → flaky, proceed; fails deterministically → real, fix it. One isolated re-run is the whole investigation — never repair-loop or block a merge on an unconfirmed flake.
- **NEVER `Process.sleep` to "fix" a flake.** Sleeps mask the race, slow every future run, and still ship it (passing *most* of the time is the same lie as hiding a failure). Synchronize instead: `assert_receive`/`refute_receive` with a timeout, `Process.monitor` + `assert_receive {:DOWN, …}`, `start_supervised!`, or poll-until-condition.
- **Don't re-run a full suite to grade already-graded code.** Per-edit hooks already ran `test.json` on touched files; a harness run already graded the stack green. A disjoint cherry-pick / clean merge of verified code needs no `precommit.full` re-run. Full suite only via a non-graded path — manual editor edits, a rebase with overlapping hunks, a branch switch, after `mix deps.get`.
- **Bound test output — never let coverage hit context.** `mix test.json --cover` dumps the entire per-module JSON (tens–hundreds of KB). Always `--output /tmp/cov.json` + `jq`; triage with `--max-failures 1` / `--failed` / a single `file:line`; drop `--cover` if you only need pass/fail.

## 🛑 MINIMALIST APPROACH FIRST

**Do exactly what is asked — nothing more, nothing less.**

- **NO** proactive features or improvements unless explicitly requested
- **NO** additional error handling beyond what's needed
- **NO** extra validation, refactoring, or documentation files
- **ALWAYS** ask before adding anything not explicitly mentioned
- **IF UNCLEAR:** Ask "Should I also do X?" before proceeding

### BUT: Minimalism Is Not Incomplete Work

**"Start minimal" means no EXTRA features — not skipping items the task implies.**

When a task says "define unified data structs," the scope is ALL structs the system needs, not "the 7 I can think of." When a source of truth exists (e.g., `method_defs/0` listing 241 methods, each implying a return type), audit it — don't cherry-pick.

**The pattern to avoid:**
1. Task says "build X for all Y"
2. Claude scopes to "build X for the obvious Y" (filtering/cherry-picking)
3. Later session discovers the gap and adds a fix-up task
4. The fix-up task does what should have been done originally

**How to catch it:**
- If the task mentions "all," audit the source of truth — don't rely on what comes to mind
- If a data source defines N items, process N items (or explain why some are excluded)
- If you're writing "for now we'll just do these 7" without being asked to limit scope — STOP. That's scoping out, not starting minimal.

**Minimalism guards against:** adding caching when nobody asked, building admin UIs "just in case," over-abstracting simple code.

**Minimalism does NOT mean:** skipping half the items in an enumerable set, cherry-picking "common" cases from a known complete list, or deferring clearly-implied work to future tasks.

## 🚨 NO PSEUDO-RIGOROUS HEDGING

**Don't gate user-requested work behind invented "evidence requirements" you cannot satisfy.**

You have no consumer telemetry. No usage counts. No signal about whether a feature will be called 12 times or 1200 times. So phrases like *"demand for this is unproven"*, *"we should wait until N consumers ask for this"*, *"is this widely needed?"*, *"only worth doing if a Nth+ use case is imminent"* are **risk-aversion theater**, not analysis. They sound rigorous; they're hedging.

- In single-developer codebases or focused teams, the developer IS the demand signal. They asked. That's the data point.
- "Wait for usage data" is a corporate-flavored instinct that doesn't apply to small teams. There's no telemetry pipeline; there's the user in front of you.
- It gaslights the user: their request is reframed as "unproven need" requiring further validation. They have to argue for what they already asked for.

**Distinguish from minimalism (the section above):**
- Minimalism = don't add features the user **didn't ask for**.
- This rule = don't refuse / defer features the user **did ask for** by inventing evidence requirements.

**Distinguish from dependency-gating (the *legitimate* "wait"):** parking work behind a **named technical / legal / market-scope trigger** with a concrete unblock path — a missing dep, an unactivated market, an **additive change that's migration-cheap to add later** — is NOT hedging. Hedging invents *demand* evidence you can't get ("wait until someone wants it"); dependency-gating cites a *structural fact* ("park until market MY activates — it's an additive `@by_country` member, so deferring forecloses nothing"). The STOP-list below targets the former, not the latter. **Build-now pressure is for *foreclosing* decisions** (annoying/migration-heavy to reverse — e.g. a geo dimension threaded through schema); an **additive** change carries no such pressure, so "build it now because one instance happens to be live" is overfit, not rigor. Reflexively reaching for build-now to avoid *looking* like you're hedging is the same theater inverted.

**Failure-mode test — if you're about to write any of these, STOP:**
- "Demand for X is unproven"
- "We should wait until..." *(unless it names a concrete technical/legal/market-scope trigger with an unblock path — that's dependency-gating, not hedging)*
- "Is this widely needed?"
- "Only worth doing if a Nth+ case is imminent"
- "Bet on usage data before building"

You don't have data either way. The honest framing is: *"I don't know if you'll use this 12 more times — that's your call."*

**What to do instead:**
- Name the **actual technical risks** (e.g., "the macro might grow more knobs than the duplication it removes," "this couples us to an upstream that breaks every release," "the test surface explodes at N+1 cases"). Those are real costs you can reason about.
- Cite **concrete precedents** when scoring complexity (see `development-philosophy.md` "Cite Ecosystem Precedents Before Crying Complexity"). Generic "this could grow" without naming a specific failure pattern is the same hedging by another name.
- If the task genuinely scores low on benefit/usefulness, score it that way honestly — don't smuggle a demand-speculation into the U/B numbers and pretend it came from analysis.

**Scope extends to task `body` fields and scoring justifications, not just live responses.** Same hedge phrases written into a task's `body` to justify B/U — "table-stakes", "increasingly expected", "now standard", "buyers expect", "competitors are starting to", "modern apps all do" — inflate the score the same way they inflate a response. Required instead: named consumer evidence (named partner asked, named competitor lever, measured conversion uplift) OR honest low score. Enforced at task-creation time by `task-writing.md` § Pre-Creation Gate (question 5).

## Git Commit / Push / PR-Create — Allowed by Default

Committing, pushing, and opening PRs are normal parts of the work — do them without asking when the task calls for it (the agent-gate / auto-land workflow, worktree branches, and shared default branches alike). Announce the action in one line, then take it; the diff and push are the recap.

The only residual caution is the general one for any hard-to-reverse action: **rewriting already-pushed history** (force-push, amend/rebase of shared commits) can destroy others' work, so confirm before doing that on a shared branch — not because commits need permission, but because history-rewrite is irreversible.

### 🚨 STAGE PATH-SCOPED — THE WORKING TREE IS SHARED, YOU WORK IN PARALLEL

**Never assume the working tree or index holds only your changes.** Unrelated WIP sits in the tree, the index may already hold files another session `git add`ed, and an auto-land harness is a second committer. A blanket stage sweeps all of it into *your* commit.

- **NEVER `git add -A` / `git add .` / `git commit -a`.** Stage explicitly: `git add <path> …`, or commit path-scoped: `git commit <path> …`. The commit then carries exactly the paths you name, regardless of what else is dirty or staged.
- **Verify the staged set before every commit** — `git diff --cached --name-only`. If a path you didn't touch is there, it's someone else's; don't commit it.
- **A pre-commit hook tripping on a file you didn't touch means foreign WIP is dirty, not that you must fix it.** Path-scoped-stash ONLY the foreign paths (`git stash push -- <their-paths>`), make your clean commit, `git stash pop`, then **re-stage whatever was staged before** so the other session's index is exactly as you found it. Never format, fix, or commit work that isn't yours to clear a hook.
- **Untracked dirs/files you didn't create:** leave them — don't `-u`-stash or `add` them.

The failure mode this guards: you path-scope your *commit* correctly but `git add -A` first, or you stash `-u` to clear a hook and bury another session's staged work. Both corrupt parallel work silently.

## Shell Safety

`rm` (including `rm -rf`) is permitted — the hook allows it; the old blanket ban caused more friction than it prevented. One habit, not a gate: before an irreversible delete, glance at the target — confirm the path is what you intend (no unexpanded `$VAR`, no wildcard catching more than you mean, not a path you didn't create or weren't asked to remove). `git rm` for tracked files keeps the removal in the diff. (Destructive *dependency / build* commands — `mix deps.clean`, `rm -rf _build` — stay consent-gated below, for slow-recovery reasons, not safety.)

## 🚨 NEVER RUN DESTRUCTIVE DEPENDENCY COMMANDS

**Never run these without explicit user consent:**

- ❌ `mix deps.clean` / `mix deps.clean --all` — deletes compiled deps; slow recovery
- ❌ `mix deps.unlock --all` — unlocks all versions
- ❌ `rm -rf _build` or `rm -rf deps` — nukes build artifacts
- ❌ `mix clean` — removes compiled app files

**What to do instead:**
- Compile error → just retry `mix compile` or `mix test`
- Specific dep issue → `mix deps.compile <dep_name> --force`
- Most "corrupt cache" issues are transient glitches

Ask before running any destructive command.

## 🚨 Integrity and Accuracy

**Never fabricate information, experience, or data.** When providing technical guidance:

- **Honest about sources:** distinguish codebase observations, general knowledge, best practices, and speculation. Never claim production experience you don't have or invent metrics/timelines/stats.
- **No false authority:** don't claim "we learned" without repo evidence; don't state "after X years in production" without evidence; use "typically/often/may/could" when uncertain.
- **Document uncertainty:** identify what you don't know, suggest validation paths, provide ranges over false precision.
- **Trace sources:** "Based on the code in file.ex...", "According to docs/FILE.md...", "Common practice in Elixir...", "This suggests..."

False technical claims cascade into bad architectural decisions, wasted resources, and damaged trust.

## 🚨 RESEARCH BEFORE ASSERTING ON NICHE TECHNICAL CLAIMS

**When the question lives outside reliable training coverage, research proactively — without being asked.** The failure mode is asserting from training-bias confidence on specs/protocols/niche APIs the model never deeply absorbed. Codex fetches reference implementations to verify; Claude defaults to "answer from memory." Close the gap.

**Research (WebFetch a known URL, WebSearch to find one) when the topic is:**
- **Wire formats / encodings** — RLP, ABI, SSZ, Protobuf, BLS, BIP-32/39/44, EIP-712, CBOR, ASN.1/DER. Fetch the spec or a reference impl before claiming byte order, length-prefix, padding, or canonical form.
- **Protocol details** — EIPs, RFCs, JSON-RPC shapes/error codes, opcode gas, exchange API quirks (signature canonicalization, error envelopes, rate-limit headers).
- **Niche / recent library APIs** — guessing signatures, return shapes, version-pinned breaking changes. If you'd write `# probably something like`, go fetch the docs.
- **Cross-implementation edge cases** — "what does X do when Y is malformed?" → check ≥2 reference impls; one impl's behavior can be a bug, agreement across two is the spec in practice.

**Don't research (use memory):** pure Elixir/OTP, stdlib, mainstream Phoenix/LiveView/Ecto/Ash, generic REST/HTTP/JSON/SQL/shell, anything already in the codebase / hex docs pulled this session / an imported CLAUDE.md.

**How to apply:** prefer WebFetch when the canonical URL is known (the EIP/RFC/hex doc/reference-impl path), WebSearch to find one; **cite what you fetched** — the citation is part of the answer, name both impls for cross-checks. If a fetch fails or is ambiguous, say so and lower confidence — don't fall back to "well, I think…" silently.

## 🚨 NO EVASION — SIT WITH THE HARD THING

**When you hit something difficult, do NOT optimize for "appearing productive" by moving to easier work.** The most common failure mode: hit a wall → silently move on → user discovers the gap later.

### Evasion Patterns (don't use without explicit user approval)

**Task abandonment:**
- "let's move on to", "we can defer this", "skip this for now"
- "let's come back to this later", "we can revisit this", "let's table this"

**Scope reduction without asking:**
- "to keep things simple, I'll skip", "for brevity, I won't"
- "that's out of scope", "not strictly necessary"

**False completion:**
- "that should be enough", "the rest is straightforward"
- "I'll leave the rest as an exercise", "the pattern is clear enough"

**Deflection to user:**
- "you might want to", "you could manually", "you'll need to handle"
- (Sometimes legitimate — but often evasion disguised as helpfulness)

### What To Do Instead

1. **Stay with it.** If it's hard, say "this is hard because X" — don't silently move on
2. **Flag blockers explicitly.** "I'm blocked on X because Y. Options: A, B, or C."
3. **Ask before deferring.** "This is taking longer than expected. Should I continue or switch?"
4. **Never write workarounds silently.** If tempted to add a fallback/default/nil-guard for missing data, ask: should this come from upstream? If yes, STOP and report it
5. **Incomplete work gets a TODO.** If you must move on, leave a tracked TODO — not a silent gap

<!-- @-import: ~/.claude/includes/harness-workflow.md -->
## Harness Workflow

OTP-native **implement → review → land** loop for roadmap-driven development. An AI orchestrator drives harness; harness dispatches headless implementer agents into isolated git worktrees, then a **cross-family reviewer AI** gates every deliverable (runs the project's checks itself, fixes inline, writes `.harness/review.json`). Optional auto-landing ff-merges approved work; a post-merge audit agent sweeps hygiene.

**Promoted from** `docs/dogfooding-workflow.md` in the harness repo — that file remains the **incubator runbook** for harness-specific history, driver-script templates, and per-batch run logs. This include is the **portfolio-wide contract**. Version-controlled source: `priv/includes/harness-workflow.md` in the harness repo; install to `~/.claude/includes/harness-workflow.md` via `mix harness.install_includes`.

### Relationship to Other Includes (Layered — No Supersession)

| Include | Role relative to harness-workflow |
|---|---|
| `workflow-philosophy.md` | **Foundation.** Evaluator separation, session-per-phase, verification-before-completion. Harness automates the loop while preserving these principles — the **reviewer AI** is the grader, never the implementer's self-report. |
| `task-prioritization.md` | **Task selection.** D/B/U scoring, `rmap next`, parallel markers, refine-don't-duplicate. Harness executes whatever rmap returns; it does not replace prioritization. |
| `worktree-workflow.md` | **Manual parallel sessions.** For hand-build work outside harness dispatch — operator-created worktrees, PR flow, post-merge audit. Harness manages its own per-run worktrees (`harness/<run-id>`); manual worktree rules still apply for hand-build sessions. |
| `dev-lifecycle.md` | **Manual five-phase chain** (`task-driver → worktree → bots → merge → audit-review`). Use when *not* driving through harness. Harness is the automated alternative for dispatchable roadmap tasks; dev-lifecycle still governs plan-and-file, pre-commit review, and post-merge audit. |
| `agent-dispatch.md` / cloud-delegation stack | **Linear/Codex/Cursor PR delegation** without a running harness BEAM. Orthogonal path — projects can use cloud delegation *or* harness; harness subsumes the dispatch+review loop when the OTP node is running. |
| `skills/harness-driver/SKILL.md` (harness repo) | **API surface contract** — MCP tools, `project_eval` patterns, `%LogRecord{}` fields, sharp edges. Load on demand when driving harness; this include covers *workflow*, the skill covers *surfaces*. |

**Adopt per repo:** `@~/.claude/includes/harness-workflow.md` in the project's `CLAUDE.md` (load-on-demand row — not eager; same pattern as `workflow-philosophy.md`).

### The Loop

```
rmap task → implementer AI (worktree) → commit harness/<run-id> → reviewer AI (THE GATE) → done | failed
                                                                              ↓ (done + auto policy)
                                                              MERGE (lander: rebase + ff-push, no re-verify)
                                                                              ↓
                                                              AUDIT (post-merge audit agent, best-effort)
```

One run = one supervised `Harness.Run` gen_statem: fork worktree off target `HEAD`, dispatch implementer, commit diff to `harness/<run-id>`, dispatch cross-family reviewer into the same worktree. The reviewer runs the project's `check_command` hint, fixes what it can, writes `.harness/review.json`. **Success = reviewer `approve`** — never implementer exit code or self-report. There is **no mechanical verification gate** in harness; judgment lives in agents.

Rejections put the task back in the queue for re-dispatch. Fix-and-approve is the near-absolute default for the reviewer.

### When to Dispatch vs Hand-Build

**Default: dispatch every pending rmap task whose dependencies are satisfied.** Hand-build only what harness cannot yet do:

- Scaffolding that reshapes harness runtime (supervision tree, dep stack, Endpoint) **while the run lifecycle itself is in flux**
- Tiny tasks — ALL of (a) D≤2, (b) ≤30 LOC across ≤3 files, (c) no harness-surface change
- UI / LiveView / heex / CSS — headless agents idle-timeout without visual reward; use tidewave + browser
- A harness gap — file via `rmap new`, fix harness, re-dispatch; do not work around by hand-building

### Running a Task

**Prerequisites:** long-lived harness BEAM (`iex -S mix` in the harness checkout), target project registered in `Harness.ProjectRegistry`, clean `git status` on the target's dispatch branch (runs fork worktrees off `HEAD`).

**Three dispatch paths** (prefer top to bottom):

1. **Native MCP — default.** `dispatch-task` (fire-and-forget) or `dispatch-await` (blocks until settle) against `http://localhost:4018/harness/mcp`. Observe via `dispatch-status`, `dispatch-transcript`, `dispatch-verdict_detail`. `scrub_anthropic_key: true` (default) forces subscription OAuth over inherited `ANTHROPIC_API_KEY`.
2. **Tidewave `project_eval` — escape hatch.** Struct-level control the flat tools don't expose (`retry_policy`, fail-over adapter lists, `subscriber: self()`). Run persists to `Harness.ResultStore` even when the eval process exits.
3. **`mix run` driver script — fallback.** Full transcript + reviewer report to terminal. See harness repo `docs/dogfooding-workflow.md` for the canonical template.

> **Never start a second driver BEAM while runs are in flight.** Boot-time worktree sweeps can prune live sibling worktrees. Drive all parallel batches from one long-lived node.

**In-flight idempotency (Task 286):** a second `dispatch-task` / `dispatch-bundle` of the same `{project, task_id}` while a non-terminal run exists returns the **existing** `run_id` (Oban `conflict?: true`), not a duplicate — a retried dispatch is safe and free.

**Write-set serialization (Task 292):** `dispatch-bundle` and cron ready-set dispatch compute each task's `touches ∪ files_to_modify` before enqueue. Tasks with overlapping write-sets are logged and serialized into later waves instead of fanned out together. Callers no longer hand-dedupe ready sets; they must keep `touches` / `files_to_modify` accurate because harness does not infer paths from task prose.

**Renderable vs executable:** `rmap delegate --to` renders native prompts for all six harness adapters (`claude`, `codex`, `cursor`, `grok`, `antigravity`, `pi`). `droid` renders but has no harness adapter — rejected at ingest. All six shipped adapters declare `worktree_isolation: true`.

### Routing & Model Management

- **Resolve `assignee` + `model` from facts, not by reading code.** `routing-brief` is the thin task-writer index: dispatchable agent roster, each agent's standing model (`Config.agent_model/1`), model availability/blocks, and per-agent KPI rollups — every metric carries `n`, no ranking. A model-capable agent with no configured model shows `model: nil, model_required: true`.
- **Scout routing (advisory).** `dispatch-recommend` returns the cross-family scout AI's per-facet `:exploit` pick (with rationale) or a safe `:explore` / `:fallback_no_data` when a facet is unmeasured; `dispatch-assess_facets` forces a fresh scout assessment. The caller decides whether to dispatch the pick — legacy composite scores are not used for routing.
- **Model is required, never defaulted.** Implementer precedence: **task `model` → `{:agent_model, agent}` → REJECT** (`{:model_required, agent}`) — harness never falls through to the CLI's ambient default. The **reviewer has no task-pin axis**: its model comes solely from `{:agent_model, agent}` for the reviewer adapter's agent (`Run.reviewer_model/1`), and a model-capable reviewer with no configured model is rejected *before* the reviewer spawns. `antigravity` (no `--model` flag) is the lone model-incapable exemption.
- **Block exhausted premium models.** A monthly budget can exhaust (e.g. cursor-Opus) while harness still lists the pair as available and routes to it. `model_availability-block_model` (with a `blocked_until` window) removes the pair from routing/cron; `model_availability-unblock_model` clears it.
- **Cost-aware A/B.** `dispatch-compare` runs one task across N adapters (optional per-adapter model overrides) and returns per-adapter `verdict` / `reviewer_diff_size` / `duration_ms` / `token_usage` for selection.

### Reading the Verdict

| `state` / `reason` | Meaning | Action |
|---|---|---|
| `:done` / `:approved` | Reviewer AI approved (possibly after inline fixes — check `reviewer_diff_size`). | Deliverable on `harness/<run-id>`. Review diff, integrate (or let auto-lander handle it), `rmap status <id> done`. |
| `:failed` / `{:review_rejected, report}` | Reviewer rejected (degenerate — near-never by design). | Read `report`. Task back in queue; re-dispatch. |
| `:failed` / `{:review_stuck, report}` | No verdict: reviewer unavailable, crashed, or missing/malformed `.harness/review.json`. | Read `report`. Fix environment or re-dispatch. |
| `:failed` / `{:worktree_failed,_}` `{:agent_spawn_failed,_}` `{:driver_crashed,_}` `{:commit_failed,_}` | Harness-side mechanical failure. | **Harness bug.** File via `rmap new`. |
| `:failed` / `{:checkout_polluted, status}` | Agent wrote outside the run worktree into the main checkout — surfaces as `:failed` **only after bounded AI recovery was exhausted** (see "Self-healing recovery" below). | Recovery declared the run dead. Likely an agent/adapter isolation issue; re-dispatch with a worktree-honoring adapter. |
| `:failed` / `{:checkout_pollution_check_failed, _}` | Post-run pollution `git status` errored. | Rare; transient git/IO. Re-run; inspect checkout if persistent. |
| `:failed` / `:timed_out` | Lifetime budget elapsed. | Raise `:lifetime_timeout` or investigate hang. |
| run process **crashed** (no settle) | gen_statem died. | **Harness bug.** File via `rmap new`. |

Failed runs retain the worktree at `result.worktree_path` for inspection. Approved runs keep branch `harness/<run-id>` after worktree teardown. Use `dispatch-verdict_detail` for the reviewer report, ratings, and `reviewer_diff_size` — no mechanical per-check stdout.

**The verdict artifact** `.harness/review.json` is `{verdict, report, facets, skills, ratings}`: `verdict` (`approve`/`reject`) is the gate; `report` is the reviewer's prose; **`facets`** (open-vocabulary routing KEY — the kind of task) and **`skills`** (v0_13 two-axis rubric, routing VALUE) feed per-facet capability routing; `ratings` is the legacy flat-score fallback. It lives under `.harness/` (excluded from staging) so it never rides in the deliverable commit.

**Self-healing recovery (the `:recovering` state).** Before settling `:failed` for an *interpretive* non-rejection failure — checkout pollution is currently the one wired call-site — the run spawns a **bounded cross-family recovery AI** (`:recovering` state, budget 1/run) with minimal context (the error term + the main checkout's `git status` + the implementer transcript tail + the failing-check output, never the full transcript). It writes `.harness/recovery.json` `{outcome: "repaired"|"dead", report, repaired}`; harness reads it mechanically and **decides nothing itself**: `repaired` resumes at `:committing` and **re-runs the reviewer gate** (never skips to `:done`); `dead` / missing / malformed settles `:failed` with the original reason. A genuine `verdict: reject` is never routed through recovery. The `Result` carries `recovery_attempts` / `recovery_outcome` / `recovery_repaired` / `recovery_token_usage`. (Tier-1 mechanical self-heal precedes it: the reviewer is re-prompted once on a missing/malformed `review.json` — `reviewer_reprompt_count`, capped at 1 — and rotates to the next cross-family candidate on a reviewer timeout — `reviewer_rotation_count`.)

### 🚨 Recover, Don't Redo — Never Burn Tokens Re-Implementing Committed Work

**A run that committed to `harness/<run-id>` already paid for the implementer. Recovering that branch costs a fraction of a fresh dispatch — re-dispatching from `pending` throws the work away and makes the agent redo all of it.** The reflex to "reset → pending → dispatch again" is a token bonfire whenever a retained branch with commits exists. Check for the branch *first*; pick the cheapest primitive that fits:

| Run state — committed `harness/<run-id>` branch exists | Recover with | Agent tokens |
|---|---|---|
| Approved but unlanded (land-cap, lander crash) | `dispatch-reland` | **zero** — pure git rebase + push |
| Committed, review-stage failure (work is good) | `dispatch-rereview` | zero implementer — re-enters at the reviewer gate |
| Committed, implement-stage incomplete/`:failed` | `dispatch-resume_failed` (`escalate: true` to re-route agent) | **re-spends implementer tokens** — a fresh implementer invocation branched off the retained commits with the failure report injected (contrast `rereview`, which re-runs only the reviewer) |
| Live `:held` run (paused, not dead) | `dispatch-resume` | none — un-pauses in place |
| **No commits / no retained branch** | reset → `pending` + fresh `dispatch-task` | full redo — **the only case where this is correct** |

**Live-run intervention (not recovery of a dead run):** `dispatch-hold` (optionally `interrupt: true`) parks a live run mid-turn, `dispatch-steer` stashes guidance applied on resume, `dispatch-resume` un-pauses in place, `dispatch-cancel` kills it (idempotent). Use hold → steer → resume to force-hand a grinding implementer to the reviewer gate instead of burning the lifetime budget.

**The gate before any reset-to-pending + re-dispatch:** `git branch -a | grep harness/<run-id>` and `git log --oneline origin/<target>..harness/<run-id>`. Commits present ⇒ recover, never redo.

**🚨 First, confirm the run actually *didn't* land — check `origin`, not your local checkout.** Under `landing_policy: :auto` the lander pushes to `origin/<target>` and **deliberately never touches your local checkout** (it ff-pushes from a detached worktree). So after an autonomous land your local `tasks.toml` is **stale**: it still reads `in_progress` for a task the lander already marked `done --shipped-in` on origin. **Reading that stale local status as "the run didn't land" is the trap** — it triggers a wasteful reset-to-`pending` + re-dispatch that *duplicate-lands already-shipped work*. Before concluding anything from task status, `git fetch origin <target> && git rebase origin/<target>` (the existing "Sync development before committing" rule) or read ground truth directly:
- `git log --oneline origin/<target>` — does it already show `task <id> -> done (shipped …)` and the agent-delivery commit? Then it **landed**; your local view was just behind. Do nothing but rebase.
- `dispatch-status <run-id>` / `result_store-list_run_records run_id:<id>` — a record with `state: done, verdict: approve` means the run succeeded; cross-check landing against origin before touching the roadmap.

> **Observed 2026-06-12 (the cautionary tale this section exists for):** three approved runs (246/249/251) landed cleanly to `origin/development` — `done --shipped-in`, audited. But the operator's local checkout hadn't rebased, so `rmap show` read stale `in_progress`. That was misread as "approved but didn't land," the tasks were reset to `pending` and re-dispatched, and task 246 **landed a second time** (duplicate delivery) before the mistake surfaced. Root cause: reading stale local state instead of rebasing on `origin` first. The lander was working perfectly the whole time.

The recovery primitives (`reland`/`rereview`/`resume_failed`) read the persisted `ResultStore` record, which **survives** worktree teardown and node restarts — so a genuinely approved-but-unlanded run (lander hit its land-cap, or a real rebase conflict retained the branch) is recoverable token-free via `dispatch-reland`. Reserve reset-to-`pending` for runs with **no committed branch and no settled record** — and only after confirming against `origin` that the work isn't already shipped.

### Parallel Dispatch

`Harness.Run.Supervisor` is a `DynamicSupervisor` — N crash-isolated runs, each with its own worktree.

- **Batch by dependency graph, then write-set.** Every pending task whose `depends_on` is satisfied can enter the ready set, but harness dispatches only the first wave whose `touches ∪ files_to_modify` are disjoint. Overlapping tasks wait for a later wave after the landed base moves forward.
- **Keep write-set fields accurate.** The dispatcher counts declared path intersections; it does not infer paths from the task body. If two tasks really edit the same function, either let write-set serialization sequence them or fold the coupled work into one rmap task (`task-prioritization.md` § "Refine, Don't Duplicate").
- **One driver BEAM** for all concurrent runs in a wave.
- **Integration order (manual landing):** smallest/isolated diffs onto target first; rebase siblings; run the project's check command on target after last merge.
- **While a wave is in flight:** do not run `rmap status` / `rmap mark` / `rmap new` in parallel sessions against the same checkout — triggers `:checkout_polluted` false-positive.

### Autonomous Landing

Projects with `landing_policy: :auto` and `target_branch`:

1. Approved run enqueues one job on serialized `landing_<name>` Oban queue (limit 1)
2. `Harness.Lander.land/1` rebases `harness/<run-id>` onto `origin/<target>` in a detached worktree
3. **ff-pushes without re-verification** — the reviewer already gated the work
4. Successful push enqueues post-merge audit; advances rmap (`done --verified --shipped-in <sha>`)

Conflict / push-rejected retains the branch for repair — never lands red. Witness notification (read-only sink) alerts the operator; it is **not** a merge gate.

**Cron manual-approval mode.** A per-project cron poller in `:auto` mode dispatches unattended; in `:manual` mode it **parks** each dispatch decision instead of enqueuing — drain the parked decisions with `dispatch-pending` and approve them with `dispatch-approve`, keeping the orchestrator in the loop for autonomous polling.

### Portfolio Conventions

- **Agent does not commit unless asked.** Staged-but-uncommitted is the default handoff between implementer and reviewer sessions (`workflow-philosophy.md` § "Implementer / Reviewer Handoff"). Harness runs commit agent work to `harness/<run-id>` automatically — that is harness's deliverable branch, not the operator's main checkout.
- **Witness notification is sakshi (read-only).** Landing outcomes notify via configured command sink; the sink grants no merge capability. Human operator reviews blocked/conflict outcomes — harness does not silently force-push past conflicts.
- **`check_command` is a hint to the reviewer.** Free text (e.g. `"mix precommit.full"`) — the reviewer runs and judges it; harness does not execute it mechanically.
- **The cross-family reviewer reads `AGENTS.md`, not your Claude skills/includes.** `AGENTS.md` is generated from `CLAUDE.md` by `claude-marketplace/scripts/sync-agents-md.sh`, which recursively inlines every `@`-import. **Regenerate it after any `CLAUDE.md` change** (`bash ~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh`, or `--dry-run` to preview) so the reviewer gates against current rules — a stale `AGENTS.md` makes codex/cursor/grok judge against rules you've already changed. **`--check` is the freshness gate** — it re-renders in memory and exits non-zero if `AGENTS.md` has drifted (diffs rendered output, not mtimes, so it catches drift in transitive `@`-imports too); wire it into CI / a pre-commit hook / the `check_command` so staleness fails loudly instead of silently. Consequence under Opus-4.8 skill-on-demand: once `CLAUDE.md` slims to the eager floor, reviewer-critical facts that *were* carried by eager includes (the `check_command` gate; that `mix test.json` / `mix dialyzer.json` emit JSON **by design** — parse for real failures, never flag the envelope; plain `mix dialyzer` is authoritative when the JSON encoder can't serialize a warning) no longer reach `AGENTS.md` via those imports. Put them in a **self-contained `## Toolchain & check commands` section in `CLAUDE.md`** so they survive the slim-down and flow into `AGENTS.md` on regen (ref: `tapakly/CLAUDE.md`, `ccxt_extract/CLAUDE.md`).
- **Delegation roster — opus last, and don't over-default to codex.** When assigning a dispatchable task to a harness adapter, prefer the external agents — **cursor, codex, grok** — and reserve the **claude/opus** adapter for work that genuinely needs it (harness-surface changes, judgment-heavy review, tasks the cheaper adapters keep bouncing). Opus tokens are precious: spend them last, not by default. Mix adapters across a wave for review coverage. A repo may override the roster in its own CLAUDE.md.
  - **Observed failure mode: reflex-routing everything to `codex`.** Run ledgers skew heavily codex-over-cursor/grok. Actively spread `assignee` across all three; reserve codex for tasks it's genuinely scored best on, not as the default.
  - **`cursor` runs on `composer-2.5-fast` by default — and that's the data-backed pick.** Pin `model = "composer-2.5-fast"` for cursor work: it's the cheapest cost-to-green in the ledger, and **every cursor capability KPI is measured on Composer** (it's a multi-model front-end, but the scores you'd route on reflect Composer, not whatever you pin). A heavier cursor model exists (`cursor-agent --list-models` lists `claude-opus-4-8-thinking-high` etc.) but is **not** the default and carries **no** capability data — pinning it *claims performance the ledger doesn't show*, so reach for it only with a concrete, named reason, not as the "design-heavy/Opus-grade" reflex. Model IDs churn; confirm with `cursor-agent --list-models`. **`model` is REQUIRED at creation for any non-`human` assignee** (`rmap new` rejects a model-less dispatchable task — "a dispatchable task must pin the LLM it runs on"; see `rmap.md` § "Pinning an LLM model"); "leave `model` unset for the agent default" does NOT work. Set `assignee` **and** `model` at task creation per `rmap.md`.

### Known Sharp Edges

- **Fresh worktrees lack `deps/` / `_build/`.** Implementer and reviewer each run project bootstrap (e.g. `mix deps.get`) when needed — budget timeouts for cold worktrees.
- **Reviewer runs the checks.** No mechanical check stack. Correct-but-not-pristine work → reviewer fixes and approves (`reviewer_diff_size` > 0).
- **Cold dialyzer PLT** dominates first reviewer check run in Elixir worktrees.
- **Nested Claude auth.** `ANTHROPIC_API_KEY` shadows subscription OAuth — scrub per run (`scrub_anthropic_key: true` or `env: %{"ANTHROPIC_API_KEY" => false}`).
- **Parallel-session rmap mutations** during a run can false-positive `:checkout_polluted` — wait for the wave or use a separate worktree.

### Repo-Specific Detail

| Need | Where |
|---|---|
| Harness API surfaces, MCP tool shapes | `skills/harness-driver/SKILL.md` in harness repo |
| Driver script template, cutover history, run log | `docs/dogfooding-workflow.md` in harness repo |
| Agent-gate architecture spec | `docs/agent-gate-workflow.md` in harness repo |
| Cross-checkout consumer setup | `skills/harness-driver/SKILL.md` § "Context A" |
| D/B/U scoring, task writing | `task-prioritization.md`, `task-writing.md` |
| Manual session/PR/audit chain | `dev-lifecycle.md`, `worktree-workflow.md` |

<!-- @-import: ~/.claude/includes/worktree-workflow.md -->
# Worktree-Per-Branch Workflow

Run multiple Claude Code sessions in parallel without files landing on the wrong branch. The mechanic: every new branch gets its own worktree under a centralized location, named after a tracking ID, cleaned up when the work merges.

**Scope:** local laptop only — Claude Code on `~/_DATA/code/<repo>/`. Cloud-delegation worktrees (Codex `codex/...`, Cursor `cursor/...`) are governed separately by `delegation-rules.md`, `agent-dispatch.md`, and `agent-pr-review.md`.

## When to Create a Worktree

**Trigger: any branch-worthy work.** Whenever Claude would otherwise run `git checkout -b <new-branch>`, create a worktree instead.

✅ Worktree warranted:
- Starting a new feature, fix, refactor, or experiment that will become its own PR
- Working on a `[P]` parallel ROADMAP task while another session is on a different branch
- Picking up a Linear issue, ROADMAP task, or scoped fix

❌ No worktree needed:
- Tiny in-place fix on the currently checked-out branch (typo, doc tweak)
- Read-only exploration / investigation / answering questions
- Running tests, builds, or quality checks against the current state

## Naming — Use a Tracking ID

Pick the worktree ID in this preference order:

1. **Linear issue** — `MW-247`, `INE-5` (when the work is tracked in Linear)
2. **ROADMAP task number** — `task-42` (local-only work tracked in `ROADMAP.md`)
3. **Branch name** — `fix-auth-redirect`, `experiment-cache-layer` (ad-hoc work)

The ID becomes both the worktree directory name AND the branch name (or a sensible derivation — branch can be `feat/<id>-<slug>` if convention dictates).

## Location — Centralized

```
~/_DATA/worktrees/<repo>/<id>/
```

- `<repo>` = repo basename (matches `~/_DATA/code/<repo>/` directory name)
- `<id>` = the tracking ID from above

**Why centralized:** sibling-of-repo (`~/_DATA/code/<repo>-<id>/`) clutters `~/_DATA/code/`; in-repo (`<repo>/.worktrees/<id>/`) gets traversed by `ripgrep` / `mix deps` / file watchers. A dedicated top-level dir is easy to grep for orphans (`ls ~/_DATA/worktrees/<repo>/`) and stays out of every other tool's path.

## Commands

```bash
# Create — branch + worktree in one step
git worktree add ~/_DATA/worktrees/<repo>/<id> -b <branch>

# Existing branch (e.g., picking up someone else's WIP)
git worktree add ~/_DATA/worktrees/<repo>/<id> <branch>

# List active worktrees in the repo
git worktree list

# Remove (after PR merge / branch deletion on remote)
git worktree remove ~/_DATA/worktrees/<repo>/<id>
git worktree prune
```

To start working in a new worktree, open a fresh Claude Code session in that directory: `claude` from `~/_DATA/worktrees/<repo>/<id>/`.

## After PR Merge — `audit-review` Is Deferred

`staged-review:audit-review` catches hygiene drift (extractions, doc gaps, missing TODO markers, ROADMAP/CHANGELOG drift) that pre-commit `code-review` may have skipped, writes `.audit/<sha>.md` reports, and lands one `audit(...)` commit on the default branch.

**Not chained off `gh pr merge`.** The post-merge tail ends at branch cleanup. The `staged-review` plugin's SessionStart hook (`check-unaudited-commits.sh`, ≥3 unaudited threshold) surfaces accumulated tails next session:

```
/staged-review:audit-status        # read-only snapshot of unaudited commits per branch
Skill(audit-review) <range>        # batched audit over the accumulated range
```

`<range>` is typically `<last-audit-sha>..<default-branch-HEAD>` — one batched pass covers all merge SHAs since the last audit.

**Manual override:** `/staged-review:audit-review [<sha>|<range>]` for catch-up audits, batch passes, or compliance asks.

**Tiny-commit fast path.** For commits ≤100 LOC AND no `lib/` (or language equivalent) touched, the skill skips Codex dispatch and writes a `verdict: clean — fast-path` report. No separate skip flag needed; if every commit in the range is fast-path-eligible, the audit is cosmetic and ends in seconds.

**Why deferred, not chained.** Bots (CodeRabbit, Copilot, Codex's GitHub bot) run between PR-open and merge, so auditing pre-bot risks re-auditing. The audit commit lands on the default branch where it's durable. Batching N merges into one pass is strictly cheaper than N synchronous passes, and `.audit/<sha>.md` artifacts indexed off merge SHAs in default-branch history remain the canonical inspection surface.

## PR Auto-Merge — Set It When You Open

When opening a PR from a worktree, immediately wire up GitHub-native auto-merge:

```bash
gh pr create --title "..." --body "..."
gh pr merge <N> --auto --squash --delete-branch
```

GitHub holds the merge until all required checks pass (CI green + `block-merge-gate / gate` clean — i.e. no `[BLOCK-MERGE]` label present) AND no requested-changes review state. No Claude / cloud-agent invocation pre-merge — the gate is GH-native.

**To hold a PR for manual review before merging:** `gh pr edit <N> --add-label "BLOCK-MERGE"`. Remove the label to release.

Full adoption guide: `plugins/staged-review/templates/auto-merge.md` (branch protection setup, `block-merge-gate.yml`, optional auto-undraft action).

## Lifecycle — Cleanup Is Part of Completion

**The work isn't done until the worktree is gone.**

Cleanup trigger: PR merged to base (auto-merge fires from § "PR Auto-Merge"), or feature branch deleted from remote.

```bash
# Same session that completes the PR merge:
git worktree remove ~/_DATA/worktrees/<repo>/<id>
git worktree prune
git branch -d <branch>  # if local branch still around
```

If you forget and later notice an orphan (worktree exists, but `git branch -vv` shows the branch as merged or `[gone]`), run the same removal commands. Orphan accumulation is what motivated the original worktree ban — keeping the directory tidy is the price of admission.

## Git Operations in a Worktree

`git commit` / `git push -u origin <branch>` / `gh pr create` on the worktree's own branch are ordinary parts of the work — do them without asking. The worktree's HEAD is the feature branch by construction, so commits land on the right branch by design.

❌ **Still confirm first (irreversible / outward, not ordinary-commit gating):**
- `gh pr merge` (governed by `delegation-rules.md` § "DON'T AUTO-MERGE PRS")
- Force-push, amend published commits, rebase **already-pushed** shared history
- `git push` to a cloud-agent's branch (governed by `delegation-rules.md` § "NEVER PUSH TO A CLOUD-AGENT'S BRANCH")

**Mental model:** commit / push / PR-create are free. The only gates left are the irreversible/outward ones — merge, history-rewrite, cloud-agent branches.

## What NOT to Do in a Worktree

- **Don't open IEx / Tidewave from a worktree.** Use the host project (`~/_DATA/code/<repo>/`) for runtime exploration. IEx in the worktree creates a parallel `_build` and recompile churn that races with the host session. Mirrors the `agent-pr-review.md` § "Tidewave is verification, not necessarily fix" constraint.
- **Don't create a worktree for read-only exploration.** Read files in-place from the main checkout. Worktrees are for branch-worthy work that will produce commits.
- **Don't commit from a non-worktree path** (the main checkout) when the work belongs to a feature branch. If you find yourself about to `git checkout -b` from the main checkout, stop and create a worktree.

## Per-Repo Override

A project can opt out of the worktree workflow by pinning a memory file under `~/.claude/projects/<project>/memory/feedback_no_worktrees.md`. Local memory always wins over global rules. Use this only when the project genuinely requires direct work on a single shared branch (e.g. a thin extraction tool with one active line of development).

## Cross-References

- `~/.claude/CLAUDE.md` § "Worktree-Per-Branch Workflow" — the rule pointer
- `~/.claude/includes/critical-rules.md` § "NEVER COMMIT WITHOUT EXPLICIT REQUEST" — the relaxed rule for tracked worktrees
- `~/.claude/includes/delegation-rules.md` — strict rules that stay strict (cloud-agent branches); auto-merge loosened for cloud-agent PRs
- `~/.claude/includes/task-prioritization.md` § "Parallel Work (`parallel` marker)" — when roadmap-tracked work uses worktrees
- `staged-review:audit-review` skill — the post-merge hygiene pass


<!-- Setup-window imports — drop once the library is fully ported; the elixir:* /
     elixir:agent-economy skills cover these on-demand afterward. -->
<!-- @-import: ~/.claude/includes/elixir-setup.md -->
## Elixir Project Setup

Standard dependencies and tooling for Elixir projects (libraries, CLI tools, escripts).

### Recommended Dependencies

| Dep | Purpose | When |
|-----|---------|------|
| ex_unit_json | `mix test.json` — AI-friendly test output | Always |
| dialyzer_json | `mix dialyzer.json` — AI-friendly dialyzer output | Always |
| styler | Auto-formatter extending `mix format` | Always |
| credo | Static analysis | Always |
| dialyxir | Dialyzer wrapper | Always |
| ex_doc | HexDocs + `llms.txt` for AI | Always |
| doctor | Doc quality gates (@moduledoc, @doc, typespecs) | Always |
| tidewave | Dev tools + Claude Code MCP | Always |
| bandit | HTTP server for Tidewave | Non-Phoenix only |
| descripex | `api()` macro, JSON Schema, MCP tools, progressive disclosure | Any project with ≥3 public modules |
| api_toolkit | InboundLimiter, RateLimiter, Metrics, Cache, Provider DSL (see `api-toolkit.md`) | API services |
| ex_dna | AST-based duplication detector | Always |
| ex_ast | AST-based code search/replace | Always |

### Version Pinning

Pinned versions below are starting points. Before adding a dep, check hex for current:
```bash
curl -s https://hex.pm/api/packages/<pkg> | jq -r .latest_stable_version
```
Hex `~>` operator (per `Version.match?/2`):
- `~> X.Y` allows everything up to (not including) the next major: `~> 2.0` = `>= 2.0.0 and < 3.0.0`; `~> 0.3` = `>= 0.3.0 and < 1.0.0`.
- `~> X.Y.Z` allows everything up to (not including) the next minor: `~> 2.0.0` = `>= 2.0.0 and < 2.1.0`; `~> 0.3.1` = `>= 0.3.1 and < 0.4.0`.

For 0.x packages, every minor bump can be breaking under hex semver — so prefer the three-segment form (`~> 0.3.1`) when you want to lock to a single 0.x minor and opt into bumps deliberately.

### mix.exs deps (libraries/non-Phoenix)

```elixir
defp deps do
  [
    {:ex_unit_json, "~> 0.4", only: [:dev, :test], runtime: false},
    {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
    {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.40", only: :dev, runtime: false},
    {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
    {:tidewave, "~> 0.5", only: :dev},
    {:bandit, "~> 1.10", only: :dev},      # non-Phoenix only
    {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
    {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
    {:descripex, "~> 0.11"},               # full dep — macros expand at compile time
    {:api_toolkit, "~> 0.1"}               # API services only
  ]
end
```

### Required: cli/0 for preferred_envs

Mix doesn't inherit `preferred_envs` from deps. Without this, `mix test.json`/`mix dialyzer.json` run in `:dev`:

```elixir
def cli do
  [preferred_envs: ["test.json": :test, "dialyzer.json": :dev]]
end
```

**Gotcha:** `preferred_envs` only fires for top-level Mix invocations. **Inside an alias step it's ignored** — the step inherits the parent alias's env (usually `:dev`). To run an alias step in `:test`, wrap with `cmd`: `"cmd MIX_ENV=test mix test.json ..."`. See § "Standard Aliases" below.

### Formatter

Add `Styler` to `.formatter.exs` plugins: `plugins: [Styler]`.

### Standard Aliases — `check.fast` + `precommit` + `precommit.full`

Three tiers split by **inner-loop cost**. The marketplace's `pre-commit-unified.sh` hook runs its **own** inline gate at commit time (format · compile · credo · doctor · sobelow · mix_audit · ash — **no tests, no dialyzer, no ex_doc**); it does **not** invoke these aliases. The aliases are for manual / CI runs: `precommit` adds the test+cover gate, `precommit.full` adds dialyzer. (`mix docs` belongs in CI / a manual run — too slow for the commit gate.)

```elixir
defp aliases do
  [
    # TagTODO/TagFIXME stay on in .credo.exs for visibility (`mix credo` shows them);
    # the gate excludes them so it fails only on real regressions, not tracked debt.
    "check.fast": [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "credo --strict --ignore TagTODO,TagFIXME"
    ],
    # Manual / CI gate (NOT run by the commit hook). Drops dialyzer; keeps tests + sobelow + doctor.
    precommit: [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "credo --strict --ignore TagTODO,TagFIXME",
      "doctor --raise",
      # `preferred_envs` (cli/0) is ignored for alias steps — set MIX_ENV explicitly.
      "cmd MIX_ENV=test mix test.json --quiet --cover --cover-threshold 85 --summary-only --exclude integration",
      "sobelow --skip"                 # --skip honors inline # sobelow_skip; drop on pure libs
    ],
    # CI mirror — adds dialyzer. Matches `elixir-ci-harness` `harness.yml`.
    "precommit.full": ["precommit", "dialyzer.json --quiet"]
  ]
end
```

**Three tiers, by inner-loop cost:**

- `mix check.fast` — format + compile-with-warnings + credo. Seconds. Run after every meaningful edit.
- `mix precommit` — adds doctor, test+cover gate, sobelow. Tens of seconds. **Manual / pre-handoff gate** — the commit hook does *not* run this; use it before handing work off when you want the test+cover gate locally.
- `mix precommit.full` — adds dialyzer. Minutes (mostly dialyzer). Run before handing off to a reviewer / matches CI; **not** for the hook path.

**Flag rationale:**

- **`credo --strict --ignore TagTODO,TagFIXME`.** TODO/FIXME are tracked-debt visibility (`development-philosophy.md` § "TODO Comment Requirements"), not regressions. Standalone `mix credo` still surfaces them so an agent can SEE the debt; the gate doesn't fail on them so PRs aren't blocked by accumulated tags.
- **`doctor --raise`.** Overrides `.doctor.exs` `raise: false` to gate CI without changing local behavior. Redundant if the repo already sets `raise: true`, but harmless.
- **`test.json --cover --cover-threshold 85 --summary-only --exclude integration`.** 85% is the project default (cartouche's empirical floor; meaningful bump from 80%, leaves headroom under typical ~87% project coverage). Critical-path repos (signing, money, crypto, wire-format encoders) raise to `95`. `--exclude integration` because local + CI lack credentials/network for live services; see `elixir-ci-harness` SKILL.md § "Integration Tag Exclusion" for the separate-workflow pattern if integration coverage is needed.
- **`sobelow --skip`.** `--skip` makes sobelow honor inline `# sobelow_skip` annotations (without it they're ignored — see "Sobelow skip/config semantics" below). Phoenix / Plug / web-facing apps only — drop on pure libraries. Pass `--config` instead if the project keeps its settings in `.sobelow-conf`.
- **`dialyzer.json --quiet`** (in `precommit.full`). Agent-friendly JSON variant (`harness.yml` uses plain `mix dialyzer` because GH Actions consumes human-readable output; agents prefer JSON). For pipeline parsing: `dialyzer.json --quiet --output /tmp/dialyzer.json` then jq.

**Sobelow skip/config semantics** (source-verified, `nccgroup/sobelow`; flag behavior drifts across versions — re-check before relying):

- Inline `# sobelow_skip [...]` annotations are honored **only with `--skip`** — bare `mix sobelow` ignores them (`lib/sobelow.ex`: `if get_env(:skip), do: combine_skips(...), else: funs`).
- The `.sobelow-skips` *fingerprint* file (written by `mix sobelow --mark-skip-all`) is read **unconditionally** — honored even without `--skip`. (So `--skip` and `.sobelow-skips` are two different mechanisms; the flag governs only the inline annotations.)
- `.sobelow-conf` (written by `--save-config`) loads **only when `--config` is passed**, and the conf then **replaces** all CLI opts (`lib/mix/tasks/sobelow.ex`) — so `mix sobelow --config --format json` silently drops `--format json` unless the conf itself sets `format:`. **Bare `mix sobelow` does NOT auto-load `.sobelow-conf`.**
- Therefore: to honor inline skips, pass `--skip`; to honor a `.sobelow-conf`, pass `--config` and put `format:` / `out:` inside the conf (not on the CLI). The marketplace pre-commit hook always passes `--skip` for this reason and does not pass `--config` (it would break its `--format json` JSON parse).

**Why split, not one alias.** The commit hook enforces a fast inline gate (no tests, no dialyzer) so the inner loop stays cheap and deterministic. The aliases layer the slower checks back on for deliberate runs: `precommit` adds the test+cover gate for pre-handoff, `precommit.full` adds dialyzer to match CI (`harness.yml`). Keeping them separate means the slow steps run where no inner-loop tax applies — CI, or a human before opening a PR — never blocking every commit.

Why no `try/rescue` aggregator by default: an agent that wants "all failures in one pass" can override at the call site (`mix format --check-formatted; mix credo --strict --ignore TagTODO,TagFIXME; mix test.json ...` joined with `;` runs every step regardless of exit). The default alias stays fail-fast because the cheapest-fail-first ordering means the agent rarely needs the aggregate — fixing the first failure usually unblocks the rest.

### Tidewave (Non-Phoenix)

Three files must agree on PORT. Registry: `~/.claude/tidewave-ports.md`. MCP registration is **project-scope** only (`.mcp.json`) — never user-scope; local/user scope collides across projects.

1. `~/.claude/tidewave-ports.md` — registry row
2. `mix.exs` alias:
   ```elixir
   tidewave: ["run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: PORT) end)'"]
   ```
3. `.mcp.json` (project root):
   ```json
   {"mcpServers":{"tidewave":{"type":"http","url":"http://localhost:PORT/tidewave/mcp"}}}
   ```

Run with `iex -S mix tidewave`. Restart Claude Code after creating/changing `.mcp.json`. Check scope with `claude mcp get tidewave`; remove user/local if present.

### Tidewave Recompile Gotcha

Tidewave runs in the same BEAM as the IEx session. After editing source, the old bytecode stays loaded — call `recompile()` via `project_eval` (or `r(SomeModule)` for one module). For the full MCP tool list, see the `tidewave-guide` skill.

### Dialyzer PLT — `:apps_direct` to avoid OOM

Default `plt_add_deps: :app_tree` walks the full transitive dep tree. For libraries / non-Phoenix projects, tidewave + bandit (dev) drag in plug, finch, mint, gun, hpax, cowlib, thousand_island, websock, mime — none of which are in `lib/`'s call graph. PLT bloats to ~800 modules and on macOS routinely OOM-kills the build at the deps-dev step (verified: peak RSS ~8 GB before kill).

Per dialyxir docs, the canonical OOM mitigation is `plt_add_deps: :apps_direct` — load only **direct** runtime deps, no transitive recursion:

```elixir
defp dialyzer do
  [
    # OOM mitigation: skip transitive deps (default is :app_tree).
    # Tidewave/bandit's HTTP stack (plug, finch, mint, gun, cowlib, etc.)
    # is not in lib/ call graph and bloats PLT to ~800 modules.
    plt_add_deps: :apps_direct,
    plt_add_apps: [:mix],
    plt_local_path: "priv/plts",
    plt_core_path: "priv/plts",
    ignore_warnings: ".dialyzer_ignore.exs"
  ]
end
```

**Verified result** on a typical onchain-stack lib (onchain_evm): 794 → 236 modules in deps-dev PLT (~70% reduction), full PLT build in 18.6s vs OOM-killed at ~10min.

**PLT location: `priv/plts/` not `_build/dialyzer/`.** PLTs in `_build/` get nuked on `mix clean` / `rm -rf _build`. Every cleanup costs a 5-10min from-scratch rebuild. `priv/plts/` survives `_build` wipes. Add `/priv/plts/` to `.gitignore`. To migrate: `find _build/dialyzer priv/plts -name '*.plt' -delete 2>/dev/null` then `mix dialyzer --plt`.

**Trade-off ladder** (per dialyxir docs):

| Option | Aggressiveness | When |
|---|---|---|
| `plt_ignore_apps: [:foo]` | Least | A few specific deps cause warnings or PLT bloat |
| `plt_add_deps: :apps_direct` | **Moderate — recommended default** | Transitive HTTP/SDK trees cause memory issues |
| `plt_apps: [explicit list]` | Most | Surgical replace; you know exactly what to include |

`:apps_direct` plus `plt_add_apps:` for any specific extras (`:mix`, `:descripex`, etc.) covers the typical library case. For project-specific optional stacks the lib doesn't call (e.g. cartouche's `:google_api_cloud_kms, :goth, :tesla, :jose`), layer `plt_ignore_apps:` on top.

**Phoenix exception:** Phoenix apps use bandit/plug at runtime and depend on transitive deps (Ecto adapters, etc.). Default `:app_tree` is usually correct; only switch to `:apps_direct` if memory is a problem, and verify no real warnings get suppressed.

**Runtime-Req exception:** if your lib has `{:req, "~> X.Y"}` as a runtime dep (not just dev-via-tidewave), `:apps_direct` excludes Req's transitive HTTP stack (finch, mint). Usually fine — Req-call warnings get suppressed via `~r/Function Req\./` in `.dialyzer_ignore.exs`. If "function unknown" warnings about Finch/Mint surface, either add them via `plt_add_apps: [:finch, :mint, ...]` or extend the regex.

### ex_doc llms.txt

`mix docs` generates `doc/llms.txt` alongside HTML — Markdown optimized for LLMs. Published packages have it at `https://hexdocs.pm/<package>/llms.txt`. Use for loading library context.

### ExDNA — Duplication Detection

```bash
mix ex_dna                            # scan for duplicates (Type I — exact)
mix ex_dna --literal-mode abstract    # Type II — catch renamed variables
mix ex_dna --min-similarity 0.85      # Type III — near-miss (structural similarity)
mix ex_dna --min-mass 50              # only flag larger clones
mix ex_dna --max-clones 10            # CI budget — exit 1 only above threshold
mix ex_dna --format json              # machine-readable
mix ex_dna --format html              # self-contained browsable report
mix ex_dna --format sarif             # GitHub Code Scanning
mix ex_dna.explain 3                  # anti-unification breakdown of one clone
```

Config: `.ex_dna.exs` in project root. Suppress intentional dupes with `@no_clone true`. Credo integration: add `{ExDNA.Credo, []}` to `.credo.exs`. LSP server pushes diagnostics to Expert/ElixirLS.

### ExAST — AST Search & Replace

```bash
mix ex_ast.search 'IO.inspect(_)'           # find debug leftovers
mix ex_ast.search 'IO.inspect(...)'         # ellipsis — any arity
mix ex_ast.replace 'dbg(expr)' 'expr'       # remove dbg, keep expression
mix ex_ast.replace --dry-run old new        # preview
mix ex_ast.diff lib/old.ex lib/new.ex       # syntax-aware diff
```

Patterns: `_` = wildcard, named vars (`expr`) capture and carry to replacement. `...` = zero-or-more (args, list items, block body). Structs/maps match partially. `_` in function-name position of `def`/`defp` patterns matches the function name even when arguments are present (e.g. `defp _(_), do: _` matches `defp helper(x), do: x + 1`). The `piped()` selector predicate distinguishes form inside the `~p`/`where` DSL — `where(piped())` matches only `|>` calls, `where(not piped())` matches only direct calls. `ExAST.search_many/3` and `ExAST.Patcher.find_many/3` run multiple named patterns in a single traversal, returning matches tagged with `:pattern`. See `development-commands.md` for the full surface (pipe awareness, `--inside`/`--not-inside`, multi-node, `~p` sigil, quoted patterns, AST/zipper input).

### Quality Gates

- Dialyzer: 0 warnings (mandatory)
- Credo: 0 issues in `--strict`
- Doctor: all public modules documented
- Tests: 80%+ coverage (95% for critical business logic)

<!-- @-import: ~/.claude/includes/agent-economy.md -->
## Agent Economy Design

Every app and library should treat AI agents as first-class consumers. Design for discovery, calling, and verification now.

### Tier 2: Self-Describing with Descripex (default)

`descripex`'s `api()` macro generates `@doc`, `@doc hints:`, compile-time validation, and runtime introspection from a single declaration:

```elixir
use Descripex, namespace: "/funding"

api(:annualize, "Annualize a per-period funding rate.",
  params: [
    rate: [kind: :value, description: "Per-period funding rate as decimal", schema: float()],
    period_hours: [kind: :value, default: 8, description: "Hours per funding period", schema: pos_integer()]
  ],
  returns: %{type: :float, description: "Annualized percentage rate", schema: float()}
)

@spec annualize(number(), pos_integer()) :: float()
def annualize(rate, period_hours \\ 8), do: ...
```

**What `api()` generates at compile time:**
- `@doc` (BEAM slot 4) + `@doc hints:` (slot 5) — human-readable + machine-readable
- `@moduledoc namespace:` — URL grouping
- `__api__/0`, `__api__/1` — runtime introspection
- `schema:` — Elixir type syntax compiled to JSON Schema via json_spec
- Param names validated against function args

**Manual `@doc` coexistence:** Place `api()` *before* an existing `@doc`. Hand-written `@doc` overwrites only slot 4 (prose); slot 5 (hints) survives. Standard for annotating existing codebases. For multi-clause functions, place `api()` before the first clause only.

**Variable opts → `emit_api/3` (v0.11+):** `api/3` preprocesses `schema:` keys at expansion and so requires a *literal* keyword-list `opts`. To declare apis in a `for`-comprehension or with macro-time variable opts (e.g. generating N declarations from a method table), use `emit_api(name, desc, opts)` — same emissions, skips preprocessing (caller pre-converts any `schema:`). It raises `ArgumentError` on literal opts, steering you back to `api/3`.

**Param kinds (the key distinction agents need):**
- `:value` — caller provides (number, date, config)
- `:exchange_data` — must be fetched first; include `source: "fetch_trades(symbol)"`

**Two modes: using and understanding.** Agents call the public API (using) *and* debug why something happened (understanding). Both need rich metadata. Annotate internal infrastructure too — a reconnection failure needs `describe(:reconnection)` to expose `calculate_backoff/2` and `should_reconnect?/1`. Public/internal is a documentation grouping concern, not a discoverability depth concern.

### Manifest & Progressive Disclosure

Flow: `api()` → compile-time `@doc` + `hints` → `Code.fetch_docs/1` → `Manifest.build(modules)` → consumed by HTTP endpoint / static JSON / MCP tools / A2A cards.

**App wrapper:**
```elixir
defmodule MyApp.Manifest do
  @modules [MyApp.Funding, MyApp.Risk, MyApp.Options]
  def build, do: Descripex.Manifest.build(@modules)
end
```

**Progressive disclosure:**
```elixir
defmodule MyApp do
  use Descripex.Discoverable, modules: [MyApp.Funding, MyApp.Risk]
end

MyApp.describe()                     # L1: modules, namespaces, function counts
MyApp.describe(:funding)             # L2: function list (name, arity, spec, description)
MyApp.describe(:funding, :annualize) # L3: full detail — params, returns, errors
```

Short names: last module segment lowercased (`MyApp.Funding` → `:funding`). Non-Descripex modules get basic listings. Or use `Descripex.Describe.describe/1-3` directly.

**MCP tool generation:**
```elixir
Descripex.MCP.tools([MyApp.Funding, MyApp.Risk])
# => [%{name: "funding__annualize", description: "...", inputSchema: %{...}}]
```
`name_style: :full` for fully-qualified names. Serve the list from your MCP endpoint.

**Validation test:** walk all public modules, assert every exported function has `:hints`. Without enforcement, hints rot.

### Consuming Descripex-Powered Libraries

Use structured discovery instead of reading source. Contracts are compile-time validated — if it compiles, they're accurate.

- **Detect:** `function_exported?(SomeModule, :__api__, 0)` or `function_exported?(MyLib, :describe, 0)`
- **Discover:** `MyLib.describe()` / `.describe(:funding)` / `.describe(:funding, :annualize)` — Level 3 has everything needed to call correctly (param order, kinds, defaults, return shape, errors, composition hints)
- **Direct module access:** `Module.__api__()` / `.__api__(:func)` — `hints` has the same fields as Level 3
- **Batch:** `Descripex.Manifest.build(modules)` — JSON-serializable map of the whole API

See the library's `CONSUMING.md` for exact output shapes.

### Tier 3: Trustless Verification (EIP-8004 ecosystem)

[ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) defines three registries — Identity, Reputation, Validation. The manifest bridges code to all three: validators read it to understand contracts, re-execute with the same inputs, and compare results.

**Static export:** `mix descripex.manifest [--app my_app] [--pretty] [--output PATH]` generates `api_manifest.json`. Ship as static artifact, reference from EIP-8004 registration.

**Design for verifiability:** pure functions re-execute trivially; stateful ops need input/output logging for replay; side effects need receipts/attestations. The more pure your core, the easier trustless verification.

### What Belongs Where

| Concern | Where |
|---------|-------|
| Param hints, response shapes, errors | `@doc` metadata in library |
| Namespace, module grouping | `@moduledoc` metadata |
| Composition hints | `@doc` metadata |
| Tier/pricing, rate limits, authentication | API layer (not library) |
| EIP-8004 registration | Agent wrapper project (Ethereum coupling stays separate) |


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
