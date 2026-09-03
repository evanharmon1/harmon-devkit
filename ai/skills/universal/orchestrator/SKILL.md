---
name: orchestrator
description: >-
  Standing mode for policy-resolved, worktree-isolated Dev flow runs. It
  dispatches scoped roles, owns run records and adjudication, monitors durable
  events, and schedules a merge queue without making product or safety choices.
  Use when coordinating one or more Dev Loop lanes. Invoke as /orchestrator.
---

# Orchestrator

Resolve and announce policy with `scripts/devflow-policy.mjs`; record resolved
rigor, rounds, breadth, roles, strategy, and disclosures in the run. Dispatch
only roles whose harness can enforce their registry write boundary: a judgment
role receives a result-only channel with no ambient workspace, shell, git, gh,
or write credential, otherwise the run blocks. Use one worktree and branch per
lane, record ownership, scope, dependencies, and file overlap, and enforce one
writer per feature branch. A lane can commit only its lane branch; the feature
owner alone assembles selected lanes, then records the included/discarded lanes
and canonical SHA in that assembly's `run.json` stage transition before pushing
the feature branch. Under council with `synthesis = true`, dispatch one fresh
implementer with the ordered source proposals and accept its artifact only when
`result.implementer.payload.synthesis_of` names those proposal identities in
that same order; record every proposal's selection outcome in the assembly.
Reject a lane that requests feature-branch write authority.

Resolve the shared run directory with `git rev-parse --git-common-dir`, never by
appending to a worktree's `.git` path (which is a file in linked worktrees).
`scripts/dev-flow-monitor.sh state-path --run-id <run-id>` returns the canonical
`<git-common-dir>/dev-flow-v2/runs/<run-id>/monitor.json` path. Keep
the schema-valid `run.json` beside it. Resolve the branch's shared active pointer
with `active-path`, and activate a new run by compare-and-swap from the prior
generation while passing the kickoff-pinned registry revision; the resulting
active pointer is the run's immutable registry binding. Every `reserve` and
`reconcile` supplies that canonical active path, run ID, branch, and generation,
and derives the canonical monitor-state path from the run ID; a superseded run
blocks even when it presents the same expected head. Before assembly, push, or
comment, first reserve an event/action/expected-head in monitor state; never
reserve or replay a merge.
For comments, also reserve the trusted immutable actor ID, deterministic marker,
SHA-256 digest of the exact body, and kickoff-pinned registry revision; the
monitor must resolve actor trust from that immutable registry snapshot, never
from a value declared only by the run or caller. On re-arm, inspect every `reserved` action's exact external
postcondition (assembled canonical SHA, remote branch SHA, or marker-bearing
comment candidates with ID/actor/marker/body digest) and reconcile it: `landed`
adopts the lowest authenticated matching comment ID and advances the durable event
cursor, `absent` keeps the reservation for one safe re-execution, and
`indeterminate` blocks the run. Never advance the cursor before this
reconciliation. A crash is therefore re-armed, not read as human cancellation.

Every terminal event has an action: lane result → validate/assemble or block;
failed gate → dispatch the bounded remediation; ready draft → run integration;
external merge → release dependents and recompute the queue; ambiguous scope,
product, safety, or consent decision → stop for a human. Persist the event ID,
reservation, observed postcondition, and action in monitor state so a resumed
session can adopt a crash-after-write action instead of duplicating it.

Bound parallel implementers by `[breadth]` and strategy and heavy local stages
by host capacity. Maintain a merge queue from complete file lists, pairwise
overlap, dependencies, stage, and re-verification cost. Recommend
oldest-terminal/highest-cost first and disclose externalities. Product, scope,
consent, and safety decisions stop for a human; re-scoping requires two traces.
