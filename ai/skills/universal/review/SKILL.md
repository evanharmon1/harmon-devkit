---
name: review
description: >-
  Drive one confidence stage at a time: dispatch challenger passes for
  challenge and reviewer passes for review, validate evidence, adjudicate,
  render durable records, compute the exit, and dispatch fresh implementers
  for confirmed fixes. Never bypass provenance, the round-push broker, or exit.
  Use when the Dev Loop enters either confidence stage. Invoke as /review.
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

## Entry gate

The input must also name the canonical `owner/repo` that will receive the PR.
Before creating the record directory, dispatching a role, or writing external
state, resolve `origin` and require it to identify that same repository:

```sh
origin_url="$(git remote get-url origin)" || exit 2
origin_repo="$(gh repo view "$origin_url" --json nameWithOwner -q .nameWithOwner)" || exit 2
[ "$origin_repo" = "$target_repo" ] || exit 2
```

Treat an absent remote, a failed identity lookup, or a mismatch as this skill
being unavailable, not as permission to guess. Return control without creating
review state so `/implement` can use its inline confidence-stage procedure for
the conventional fork topology where `origin` is the writable fork and the PR
targets upstream.

## Dispatch and receipt

The dispatcher is a capability boundary: dispatch a challenger or reviewer
only through a harness that provides a read-only reviewed snapshot (the
captured diff, source content, and applicable design record) while denying
shell, git, `gh`, network write, and external credentials, except for the
result-return channel. If that read/write split cannot be installed and
verified, refuse the dispatch and record a blocker; prose in the agent file is
never a substitute for this boundary. Give every pass the captured base/head,
run identity, policy, finder slot, and that snapshot. Include the complete
validated finding records from every earlier round of this same stage, not
merely their IDs, so the role can compare evidence before asserting
`repeat-of` or `supersedes`; an empty list is explicit in round 1.

For `challenge`, dispatch every primary finder in `[stage.challenge].finders`
to the `challenger` role. For `review`, do the same for
`[stage.review].finders` using the `reviewer` role. Retry a failed finder only
through its configured `finder_fallbacks`; do not silently reduce coverage.
The registry invocation is the role's evidence source, not itself a result
envelope: the dispatched role binds that output to the supplied run, scope,
round, slot, and producer identity and returns `result.challenger` or
`result.reviewer`. A harness that cannot enforce that binding makes the finder
unavailable; the orchestrator never fabricates runtime-attested envelope data.
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

After each adjudication, build the issue comment from the validated source
result envelopes, that round's adjudication JSON, and its exit projection in
fenced JSON, then append the human table from `scripts/render-dev-flow.sh
round-table --record <record> --stage <stage> --round <N>`. Scan and redact that
exact replayable body before posting; the rendered table alone is never the
durable evidence. Before any GitHub write, compute the exact body digest and
reserve the comment through `scripts/dev-flow-monitor.sh reserve`, binding the
active run generation, expected head, deterministic run/stage/round/sequence
marker, actor ID, and the registry revision pinned into the active run at
kickoff. Only then
post. On re-arm, fetch the complete bounded comment candidate set and pass it to
`reconcile`; the monitor validates the actor against that pinned registry,
hashes each candidate body, and adopts the lowest authenticated matching
comment ID. Post once only after `reconcile` returns `retry`; `block` is
terminal.

After adoption, append the canonical comment ID, immutable actor ID, display
login, `sha256:` body digest, and marker fields to
`run.json.evidence_comments`, validate the run record, then reserve and apply an
update to its issue comment through the same monitor. A crash between evidence
creation and run-record publication therefore resumes from the adopted monitor
postcondition and cannot orphan an unindexed comment. Before a draft exists,
the issue comment is the durable projection; terminal blockers are rendered
with `blocker-comment` and use the same reserve-first path. At draft creation,
use `scripts/render-dev-flow.sh publish` for the PR-body projection without
deleting the local record.

Act only on the second returned outcome. `continue` dispatches the next pass
when no confirmed remediation exists (including an empty or entirely
declined/deferred round); otherwise it dispatches a fresh bounded implementer,
commits the one fix round, and pushes only through `scripts/round-push.sh` by
path. `diverging` permits only deletion or restructuring of round-created
scaffolding; `capped` with P0/P1 records an intervention and blocker, then
stops before a PR. A `converged` result advances by default, but an attributable
operator may override it upward to exactly one additional pass while the
resolved stage cap still has headroom. Before dispatch, append that operator's
reason and attribution to `run.json.interventions` as `kind: other`; refuse the
override when no round remains. Never override an exit downward or reinterpret
the script's outcome. Without that recorded upward override, a terminal
`challenge` clean transitions to `review` and a terminal `review` clean names
security as next. Deferred P2s remain recorded for integration.
