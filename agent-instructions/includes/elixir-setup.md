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
| ex_slop | Credo plugin — AI-generated-code antipatterns; rides `credo --strict` (see `ex-slop.md`) | Always |
| reach | PDG/SDG — `reach.check --arch --smells` architecture + smell gate (see `reach.md`) | Always |

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
    {:ex_unit_json, "~> 0.6", only: [:dev, :test], runtime: false},
    {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
    {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.40", only: :dev, runtime: false},
    {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
    {:tidewave, "~> 0.5", only: :dev},
    {:bandit, "~> 1.10", only: :dev},      # non-Phoenix only
    {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
    # reach 2.8.x still declares `ex_ast ~> 0.12.0` upstream. Override it rather than
    # pinning back to 0.12 — reach only uses APIs ex_ast 0.13 retains, verified against
    # `mix reach.check` (bourse, tapakly, zen_websocket; six more repos run the same pair).
    {:ex_ast, "~> 0.13.1", override: true, only: [:dev, :test], runtime: false},
    {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
    {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
    {:descripex, "~> 1.0"},               # full dep — macros expand at compile time
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

**Second gotcha — an exported `MIX_ENV` beats `preferred_envs` entirely.** `cli/0` only applies when `MIX_ENV` is *unset*. `MIX_ENV=dev mix precommit` (or a shell that exported it once) runs the whole gate in `:dev`; on a Phoenix app `ash.setup`/`ecto.setup` then targets the dev database and the failure surfaces as a **Postgres authentication error** — it reads like broken credentials, not a wrong env (observed on a dispatched run; only the reviewer traced it back). Say it before the first expensive step:

```elixir
@test_env_guard ~s(sh -c '[ -z "${MIX_ENV:-}" ] || [ "$MIX_ENV" = test ] || { echo "This gate runs in MIX_ENV=test via cli/0 preferred_envs, but an exported MIX_ENV=$MIX_ENV overrides that. Run: env -u MIX_ENV mix <task>" >&2; exit 1; }')
# first step of any alias declared `:test` in cli/0:
"cmd " <> @test_env_guard
```

Mix does not export `MIX_ENV` into `mix cmd` subprocesses, so the guard reads the ambient shell value, not Mix's resolved env. The `"cmd MIX_ENV=test mix test.json ..."` form in the aliases below is immune (it sets the env explicitly) — the guard matters for aliases that *rely* on `preferred_envs` (Phoenix `precommit: :test`, `ci: :test`).

### Formatter

Add `Styler` to `.formatter.exs` plugins: `plugins: [Styler]`.

**Styler sets your Elixir floor to 1.17.** It rewrites `DateTime.add/3` into `DateTime.shift/2` whenever the running Elixir is ≥ 1.17, so `mix format` writes 1.17-only calls regardless of what `elixir:` claims. Declare `elixir: "~> 1.17"` (or higher) — a lower floor is a build that only works by accident.

### Standard aliases — check scope comes from verification-policy.md

`~/.claude/includes/verification-policy.md` owns scheduling. This template keeps
full QA separate from the implementation/review command. Focused tests are chosen
for the changed behavior, not baked into a whole-suite dispatch alias.

| Alias | Contents | Role |
|---|---|---|
| `check.fast` / `check.dispatch` | Format check and compile with warnings as errors | Scoped code verification; add focused tests |
| `precommit` | Compatibility name for comprehensive checks below | Full QA, not an automatic commit/handoff trigger |
| `precommit.full` / `ci` | Full suite, coverage and project analyzers | Post-merge audit + QA |

```elixir
defp aliases do
  [
    "check.fast": ["format --check-formatted", "compile --warnings-as-errors"],
    "check.dispatch": ["check.fast"],
    precommit: [
      "check.fast",
      "credo --strict --ignore TagTODO,TagFIXME",
      "doctor --raise",
      # preferred_envs is ignored for alias steps; 85 is this template's QA coverage floor.
      "cmd MIX_ENV=test mix test.json --quiet --cover --cover-threshold 85 --summary-only --exclude integration",
      "sobelow --skip --exit Low"
    ],
    "precommit.full": [
      "precommit",
      "ex_dna --max-clones 0",
      "dialyzer.json --quiet",
      "reach.check --arch --smells"
    ],
    ci: ["precommit.full"]
  ]
end
```

Register `check.dispatch` as the scoped hint and `ci` as full QA where supported.
A registration does not prove that an automatic audit is configured or has run.
Relevant live/security verification remains required for the changed behavior.

**Flag rationale:**

- **`credo --strict --ignore TagTODO,TagFIXME`.** TODO/FIXME are tracked-debt visibility (`development-philosophy.md` § "TODO Comment Requirements"), not regressions. Standalone `mix credo` still surfaces them so an agent can SEE the debt; the gate doesn't fail on them so PRs aren't blocked by accumulated tags. ExSlop rides this step as a Credo plugin — no separate alias entry (see § "ExSlop" below).
- **`doctor --raise`.** Overrides `.doctor.exs` `raise: false` to gate CI without changing local behavior. Redundant if the repo already sets `raise: true`, but harmless. A `doctor` dep without a `doctor` alias step is a dead gate — the dep alone enforces nothing.
- **`test.json --cover --cover-threshold 85 --summary-only --exclude integration`.** 85% is the project default (cartouche's empirical floor; meaningful bump from 80%, leaves headroom under typical ~87% project coverage). Critical-path repos (signing, money, crypto, wire-format encoders) raise to `95`. `--exclude integration` because the credentials/network for live services are not present in a normal run; run the integration tag separately where they are. **The threshold must live in the alias, not only in `AGENTS.md` prose** — a coverage tier enforced by telling the agent about it is not enforced.
- **`ex_dna --max-clones 0`.** Zero-tolerance clone gate. Placed in `precommit.full` for the complete project comparison during audit + QA. Generated/vendor clones: configure ExDNA ignore paths, don't relax the threshold.
- **`sobelow --skip --exit Low`** (full QA; also use for a relevant security change). `--skip` makes sobelow honor inline `# sobelow_skip` annotations (without it they're ignored — see "Sobelow skip/config semantics" below). `--exit Low` fails on Low-confidence findings too: `Low` is the only threshold that catches `Traversal.FileModule` on an operator-supplied path, and every committed skip is Low or Medium, so nothing below Low exists to suppress. Phoenix / Plug / web-facing apps only — drop both steps on pure libraries. A `.sobelow-conf` needs no flag — it auto-loads since 0.14.1 (`--no-config` opts out).
- **`dialyzer.json --quiet`** (precommit.full). Agent-friendly JSON variant (agents prefer JSON over the human-readable default). For pipeline parsing: `dialyzer.json --quiet --output /tmp/dialyzer.json` then jq.
- **`reach.check --arch --smells`** (precommit.full only). Needs the full SDG — too slow for the inner loop or the dispatch gate. `--arch` validates against `.reach.exs`; `--smells` runs the cross-function smell surface (see `reach.md` for the Credo overlap). An empty `.reach.exs` (`[]`) is a valid no-policy — `--arch` passes vacuously until you populate layers/boundaries, so populate it as the architecture settles.

**Never put `format` (the rewriter) in a gate.** `format` mutates the tree; `format --check-formatted` checks it. A `ci` alias that runs `format` and then `format --check-formatted` can never fail on formatting — the check verifies what the previous step just wrote. Gates check; humans and hooks rewrite.

**Sobelow skip/config semantics** (source-verified against 0.15.0 tarball 2026-08-09, `nccgroup/sobelow`; flag behavior drifts across versions — re-check before relying):

- Inline `# sobelow_skip [...]` annotations are honored **only with `--skip`** — bare `mix sobelow` ignores them (`lib/sobelow.ex`: `if get_env(:skip), do: combine_skips(...), else: funs`).
- The `.sobelow-skips` *fingerprint* file (written by `mix sobelow --mark-skip-all`) is *read* unconditionally but **suppresses findings only with `--skip`** (`lib/sobelow.ex` `loggable?/2`: `!(get_env(:skip) && (new_skip || legacy_skip))`) — one flag gates both mechanisms, inline annotations and the skip file; a plain `mix sobelow` prints skipped findings by design. Matching uses only the hash column; the `Type,file:line` prefix is display/sort metadata — but the line number feeds the `phash2` input (`[type, vuln_source, filename, vuln_line_no]`, `lib/sobelow/finding.ex`), so a line shift still invalidates the entry via a changed hash.
- `.sobelow-conf` (written by `--save-config`) **auto-loads by default since 0.14.1** (`config = Keyword.get(opts, :config, true)` in `lib/mix/tasks/sobelow.ex`); `--no-config` opts out. **CLI args take precedence** over conf values (`Keyword.merge(config_settings(conf_file), opts)`) — so `mix sobelow --format json` keeps JSON output regardless of the conf's `format:`. 0.15.0 additionally drops action keys (`version`, `details`, `all_details`, `save_config`, `diff`) from the conf with a warning — a checked-in conf can no longer make the scanner exit without scanning. (Pre-0.14.1 behavior was the reverse: conf only with `--config`, and it replaced CLI opts.)
- `--mark-skip-all` **rewrites `.sobelow-skips` merged + deduped + sorted as of 0.15.0** (`--legacy-skips` restores the historical append-only mode). It still never removes entries that no longer match a live finding, so the prune cadence for stale-entry bloat remains `rm .sobelow-skips && mix sobelow --mark-skip-all`.
- Therefore: to honor inline skips, pass `--skip`; a `.sobelow-conf` needs no flag. The marketplace pre-commit hook always passes `--skip` for this reason; its `--format json` is safe with or without a conf since the CLI wins.

**Why four aliases, not one.** The commit hook enforces a fast inline gate (no tests, no dialyzer) so the inner loop stays cheap and deterministic. Each further tier adds exactly the checks its consumer can afford: the dispatch reviewer gets the clone + security gate without paying for a PLT; CI gets the graph and PLT invariants once per wave. Keeping them separate means the slow steps run where no inner-loop tax applies — never blocking every commit.

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

### ExSlop — Credo Plugin for AI-Slop

Prepend to `.credo.exs`: `plugins: [{ExSlop, []}]`. Runs inside every `credo --strict` step — no alias entry of its own. Typical relaxations: `{ExSlop.Check.Readability.NarratorDoc, false}` on projects that keep narrative moduledocs by design. Full check list, categories, and `vibe_kit`'s auto-patcher: `ex-slop.md`.

### Reach — Architecture Gate

`.reach.exs` at project root drives `reach.check --arch` (layers, forbidden deps/calls, boundaries, effects). Start with `[]` and populate as the architecture settles — an empty policy passes vacuously. Gate lives in `precommit.full` only (needs the full SDG). Full CLI (`reach.map` / `reach.inspect` / `reach.trace` / `reach.otp`), the smell catalogue, and the `.reach.exs` key reference: `reach.md`.

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
- Tests: 85%+ coverage (95% for critical business logic) — gated in the alias, not in prose
- ExDNA: 0 clones (`--max-clones 0`)
- Reach: `reach.check --arch --smells` clean against `.reach.exs`
