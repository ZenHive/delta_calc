# `:domain_pending` tags executable domain invariants that encode the TARGET
# post-fix state for an open roadmap task (see DomainInvariantsTest). They are
# red until their task lands, so they are excluded from the default run to keep
# the harness bundle green; the fixing task removes its tag. Run them on demand
# with `mix test --include domain_pending`.
ExUnit.start(exclude: [:domain_pending])
