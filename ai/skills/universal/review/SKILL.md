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
run directory, and the active run identity. The policy is a
`schema_version = 2` `.devflow.toml` resolved through
`scripts/devflow-policy.mjs`; this skill carries no interpreter for the legacy
or v1 shape, and a reader refusal is a blocker carrying the reader's own
migration message, never grounds to hand-decode the file or guess a cap
(harmon-devkit#604). Create the record directory before
the first dispatch and retain `run.json`, `policy.json`, `passes/`,
`adjudications/`, and `verdict.json` there; `/integrate` consumes that exact
directory. Capture and refresh base and canonical head before every logical
round. A changed head invalidates an unadjudicated pass rather than letting it
describe a new tree.

When the run has a lane assembly, the first confidence pass after that
assembly must review the latest implement transition's exact
`assembly.canonical_head`. Compare it before dispatch and again on receipt; a
different head blocks until the feature owner records the actual assembly
rather than certifying an unauthenticated tree.

## Stage invariants

Every confidence stage carries the mandatory round-two scaffolding checkpoint
as an invariant, independent of its current control-flow wording. Before any
round-two adjudication can cause another pass or remediation dispatch, classify
each finding whose subject exists only because an earlier round of that same
stage added it, and record exactly one disposition: delete the scaffolding,
restructure it to an invariant, or keep it as genuinely in scope with the
reason. A rewrite of `continue`, remediation, or exit handling must preserve
this checkpoint; no path may harden round-one scaffolding first and classify it
later.

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

When the resolved cap is `0` for the requested stage, dispatch no finder,
create no pass, round, or adjudication, and do not invoke a model. Run the exit
computation immediately and advance only when its disabled-stage verdict says
`action: advance`; any other result is a blocker. A zero cap disables the
stage—it is not permission to manufacture a clean round.

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
`[stage.review].finders` using the `reviewer` role. Retry an unavailable primary
once as that same primary; only after that retry fails may the ordered
`finder_fallbacks` chain be consumed. Do not silently reduce coverage.
Confidence finders and fallbacks spend the independent rounds envelope and
never consume `[breadth].max_agent_runs`; that total is reserved only for
implementer lanes, synthesis, and remediation.
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
--json`, capturing both its status and JSON projection. Materialize the trusted history and head map from the feature-owner's
verified branch state before dispatch; never let a finder supply them. Its
provenance and fingerprint corrections are preconditions, not an advisory
reviewer assertion. A recognized terminal nonzero status with a valid blocker
projection is handled as that blocker. Any other command failure, missing or
malformed projection, or indeterminate verification result authorizes no
adjudication and no round-evidence publication: persist the diagnostic, render
and reserve-first publish a terminal blocker instead, then stop. If a valid
projection reports `action: dispatch` because no
complete round for the refreshed canonical head survived, invalidate the stale
pass and dispatch the returned `next_round`; never adjudicate it. Any
`action: escalate` projection is terminal: persist it as `verdict.json`, render
the blocker, and stop. For an incomplete logical round (`finder_unavailable`
or `breadth_exhausted`), that blocker carries the accepted partial finding IDs;
the round has no adjudication target and must never reach the second exit call.
Only an `action: adjudicate` projection authorizes the orchestrator
to correct the finding facts and write one schema-valid
`adjudications/<stage>-r<N>.json`, containing the schema-supported priority,
disposition, classification, reason, and evidence for every finding, validated
against every accepted pass. Cite any verified provenance/fingerprint
correction in `evidence`; keep the machine values in the verification/exit
projection rather than adding fields the adjudication schema rejects. Only
after that write, run the exit command again with the same trusted repository
history and head map, persist its returned JSON as `verdict.json`, and act on
that second outcome.

After each adjudication, keep the immutable source envelopes locally, but build
the fenced JSON public comment only from a verification-bound projection. Join
the validated source facts to `verdict.json.verified_findings` by finding ID and
publish only the verified or corrected provenance and fingerprint values,
never the producer's superseded assertions. A missing, unverified, duplicate,
or mismatched projection is a blocker, not permission to fall back to raw
envelopes. Include that verified projection, the round's adjudication JSON, and
its exit projection, then append the human table from
`scripts/render-dev-flow.sh round-table --record <record> --stage <stage>
--round <N>`.

Scan and redact the complete verification-bound projection first. If the final
destination limit would be exceeded, split the sanitized projection
deterministically into an ordered sequence, reserving room in every segment for
its canonical run/stage/round/sequence marker. Splitting is a projection-layer
operation and must finish before reserving any comment. Append each unique
sequence marker, scan the exact segment again, compute its digest, then reserve,
post, and reconcile segments strictly in sequence; each reservation binds the
active run generation, head, role, finder, actor ID, registry revision, marker,
and exact segment digest. Never reserve an oversized unsplit body. On re-arm,
fetch the complete bounded candidate set for that segment and pass it to
`reconcile`; the monitor validates the candidates' run, head, role, finder,
actor, marker, and digest bindings, hashes their bodies, and adopts the lowest
authenticated match. Post once only after `reconcile` proves the candidate set
has no authenticated match and returns `retry`; `block` is terminal.

After adoption, append the canonical comment ID, immutable actor ID, display
login, `sha256:` body digest, and marker fields to
`run.json.evidence_comments` only when it is absent. On re-arm, first search by
both comment ID and canonical marker: when ID, immutable actor ID, digest, and
every marker field match exactly, adopt the existing entry without appending;
display login is non-authoritative metadata and never participates in evidence
identity or tamper comparison. When an ID or marker matches with conflicting
authenticated content, block. Validate the run record,
then reserve and apply an update to its issue comment through the same monitor.
A crash between evidence creation and run-record publication therefore resumes
from the adopted monitor postcondition and cannot orphan an unindexed comment or
duplicate its index entry. Before a draft exists, the issue comment is the
durable projection; terminal blockers are rendered with `blocker-comment` and
use the same reserve-first path. At draft creation, use
`scripts/render-dev-flow.sh publish` for the PR-body projection without deleting
the local record.

Act only on the second returned outcome. `continue` dispatches the next pass
when no confirmed remediation exists (including an empty or entirely
declined/deferred round); otherwise it dispatches a fresh bounded implementer,
commits the one fix round, and pushes only through `scripts/round-push.sh` by
path. Immediately before that remediation dispatch, the feature owner must
reserve its deterministic dispatch event through `reserve-agent-run` against
the same run-pinned `[breadth].max_agent_runs`; an exact re-arm adopts the
reservation, while exhaustion records `breadth_exhausted`, renders the blocker,
and stops before invoking the implementer. The stage-invariant round-two
checkpoint above applies before this dispatch and before a no-remediation next
pass alike.
`diverging` permits only deletion or restructuring of round-created
scaffolding; `capped` with P0/P1 records an intervention and blocker, then
stops before a PR. A `converged` result advances by default, but an attributable
operator may override it upward to exactly one additional pass while the
resolved stage cap still has headroom. Before dispatch, append that operator's
reason and attribution to `run.json.interventions` as `kind: other`; refuse the
override when no round remains. Never override an exit downward or reinterpret
the script's outcome. Without that recorded upward override, a terminal
`challenge` clean transitions to `review` and a terminal `review` clean names
security as next. Deferred P2s remain recorded for integration.
