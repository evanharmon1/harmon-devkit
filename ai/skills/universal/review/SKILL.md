---
name: review
description: >-
  Drive one confidence stage at a time: dispatch challenger passes for
  challenge and reviewer passes for review, validate evidence, adjudicate,
  render durable records, compute the exit, and dispatch fresh implementers
  for confirmed fixes. Never bypass provenance, the round-push broker, or exit.
  Invoke as /review.
disable-model-invocation: true
---

# Review

`/review` owns both confidence stages. Its input names `challenge` or `review`,
the base and head, policy, registry, run directory, and the active run identity.
Capture and refresh the scope before every logical round.

For `challenge`, dispatch every primary finder in `[stage.challenge].finders`
to the `challenger` role. For `review`, do the same for
`[stage.review].finders` using the `reviewer` role. Retry a failed finder only
through its configured `finder_fallbacks`; do not silently reduce coverage.
Reject a result until `scripts/validate-result-schemas.mjs envelope` validates
it and its run, base, head, stage, round, and finder match the captured scope.

Before adjudication, run `scripts/dev-flow-exit.sh --run <record> --stage
<stage> --policy <policy> --current-head <head> --json`. Its provenance and
fingerprint checks are preconditions, not an advisory reviewer assertion.
Persist `run.json`, received passes in `passes/`, adjudications in
`adjudications/`, `policy.json`, and the returned `verdict.json`. Render
PR-body sections only through `scripts/render-dev-flow.sh`.

Act only on the returned outcome: `continue` dispatches a fresh implementer
for confirmed fixes, then commits once and pushes by path through
`scripts/round-push.sh`; `diverging` permits only delete or restructure of
round-created scaffolding; `capped` with P0/P1 records intervention and stops
before a PR; terminal clean names the next stage. Deferred P2s remain recorded.
