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

`/review` owns both confidence stages, not the security or integration stages.
Its input names `challenge` or `review`, the base and head, policy, registry,
run directory, and the active run identity. Create the record directory before
the first dispatch and retain `run.json`, `policy.json`, `passes/`,
`adjudications/`, and `verdict.json` there; `/integrate` consumes that exact
directory. Capture and refresh base and canonical head before every logical
round. A changed head invalidates an unadjudicated pass rather than letting it
describe a new tree.

## Dispatch and receipt

The dispatcher is a capability boundary: dispatch a challenger or reviewer
only through a harness that provides a read-only reviewed snapshot (the
captured diff, source content, and applicable design record) while denying
shell, git, `gh`, network write, and external credentials, except for the
result-return channel. If that read/write split cannot be installed and
verified, refuse the dispatch and record a blocker; prose in the agent file is
never a substitute for this boundary. Give every pass the captured base/head,
run identity, prior finding ids, policy, finder slot, and that snapshot.

For `challenge`, dispatch every primary finder in `[stage.challenge].finders`
to the `challenger` role. For `review`, do the same for
`[stage.review].finders` using the `reviewer` role. Retry a failed finder only
through its configured `finder_fallbacks`; do not silently reduce coverage.
Reject a result until `scripts/validate-result-schemas.mjs envelope` validates
it and its run, base, head, stage, round, finder, and previously seen ids match
the captured scope. Persist each immutable accepted result in `passes/` before
using it. A finder failure is retried by its configured fallback and the
substitution is recorded; exhausted coverage is a blocker, never a smaller
round disguised as complete.

## Verify, adjudicate, publish, exit

Before adjudication, run `scripts/dev-flow-exit.sh --run <record> --stage
<stage> --policy <policy> --current-head <head> --repo-root <trusted-repo>
--history <record>/history.json --heads <record>/heads.json --verification-only
--json`. Materialize the trusted history and head map from the feature-owner's
verified branch state before dispatch; never let a finder supply them. Its
provenance and fingerprint corrections are preconditions, not an advisory
reviewer assertion. Use that first projection only to correct the finding facts. The orchestrator
then writes one schema-valid `adjudications/<stage>-r<N>.json`, containing the
schema-supported priority, disposition, classification, reason, and evidence
for every finding, and validates it against every accepted pass. Cite any
verified provenance/fingerprint correction in `evidence`; keep the machine
values in the verification/exit projection rather than adding fields the
adjudication schema rejects. Only after that write, run the exit command again
with the same trusted repository history and head map, persist its returned JSON as
`verdict.json`, and act on that second outcome.

After each adjudication, render immutable evidence through
`scripts/render-dev-flow.sh round-table --record <record> --stage <stage>
--round <N>` and post it immediately on the issue with its deterministic run,
stage, round, and sequence marker. Before a draft exists, that issue comment is
the durable projection; terminal blockers are rendered with `blocker-comment`
and posted beside it. At draft creation, use `scripts/render-dev-flow.sh
publish` for the PR-body projection without deleting the local record.

Act only on the second returned outcome. `continue` dispatches the next pass
when no confirmed remediation exists (including an empty or entirely
declined/deferred round); otherwise it dispatches a fresh bounded implementer,
commits the one fix round, and pushes only through `scripts/round-push.sh` by
path. `diverging` permits only deletion or restructuring of round-created
scaffolding; `capped` with P0/P1 records an intervention and blocker, then
stops before a PR. A terminal `challenge` clean transitions to `review`; a
terminal `review` clean names security as next. Deferred P2s remain recorded
for integration.
