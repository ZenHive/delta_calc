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

## After PR Merge — Audit Is Deferred

Post-merge audit is **not chained off `gh pr merge`**; the post-merge tail ends at branch cleanup. In harness-driven repos the audit is harness's post-merge QA (see `harness-workflow.md`); elsewhere it is the full-QA pass defined in `verification-policy.md`, run on the landed revision as a separate, nonblocking responsibility. Batching N merges into one pass is strictly cheaper than N synchronous passes, and bots (CodeRabbit, Copilot, Codex's GitHub bot) run between PR-open and merge, so auditing pre-bot risks re-auditing.

## PR Auto-Merge — Set It When You Open

When opening a PR from a worktree, immediately wire up GitHub-native auto-merge:

```bash
gh pr create --title "..." --body "..."
gh pr merge <N> --auto --squash --delete-branch
```

GitHub holds the merge until all required checks pass (CI green + `block-merge-gate / gate` clean — i.e. no `[BLOCK-MERGE]` label present) AND no requested-changes review state. No Claude / cloud-agent invocation pre-merge — the gate is GH-native.

**To hold a PR for manual review before merging:** `gh pr edit <N> --add-label "BLOCK-MERGE"`. Remove the label to release.

Full adoption guide: `plugins/review/templates/auto-merge.md` (branch protection setup, `block-merge-gate.yml`, optional auto-undraft action).

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
- `~/.claude/includes/critical-rules.md` § "Git Commit / Push / PR-Create — Allowed by Default" + § "STAGE PATH-SCOPED" — commits are allowed; staging stays path-scoped
- `~/.claude/includes/delegation-rules.md` — strict rules that stay strict (cloud-agent branches); auto-merge loosened for cloud-agent PRs
- `~/.claude/includes/task-prioritization.md` § "Parallel Work (`parallel` marker)" — when roadmap-tracked work uses worktrees
- `verification-policy.md` § Post-merge audit + QA, `harness-workflow.md` — the post-merge pass
