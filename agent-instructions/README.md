# Pinned agent instruction inputs

`includes/*.md` are versioned generation inputs, shared by `CLAUDE.md` and the
repository generator. Their initial contents were extracted byte-for-byte from
these six expanded imports in committed `AGENTS.md` at
`520b1059ce12a4f6ccb47301d38f7045f116010c`, preserving the policy restored by task 61.
They were not copied from an audit host installation. The original import names
were `~/.claude/includes/<filename>`.

Git records the source version and all intentional updates. Normal generation
uses only this checkout; an older or missing host installation has no effect.
See `CLAUDE.md` under “AGENTS.md is generated” for generation, freshness, regression,
and explicit include-refresh commands. Review refresh diffs for policy changes;
an explicit refresh can replace current policy with older policy if given older
inputs. No automatic update or host fallback is performed.
