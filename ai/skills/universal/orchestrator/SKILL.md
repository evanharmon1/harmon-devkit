---
name: orchestrator
description: >-
  Standing mode for policy-resolved, worktree-isolated Dev flow runs. It
  dispatches scoped roles, owns run records and adjudication, monitors durable
  events, and schedules a merge queue without making product or safety choices.
  Invoke as /orchestrator.
disable-model-invocation: true
---

# Orchestrator

Resolve and announce policy with `scripts/devflow-policy.mjs`; record resolved
rigor, rounds, breadth, roles, strategy, and disclosures in the run. Dispatch
only roles whose harness can enforce their registry write boundary: a judgment
role receives a result-only channel with no ambient workspace, shell, git, gh,
or write credential, otherwise the run blocks. Use one worktree and branch per
lane, record ownership, scope, dependencies, and file overlap, and enforce one
writer per feature branch. A lane can commit only its lane branch; the feature
owner alone assembles selected lanes, records the included/discarded lanes and
canonical SHA in `run.json`, then pushes the feature branch. Reject a lane that
requests feature-branch write authority.

Maintain durable monitor state at `.git/dev-flow-v2/runs/<run-id>/monitor.json`
and use `scripts/dev-flow-monitor.sh`. Before assembly, push, or comment, first
reserve an event/action/expected-head in that file; never reserve or replay a
merge. On re-arm, inspect every `reserved` action's exact external
postcondition (assembled canonical SHA, remote branch SHA, or marker-bearing
comment) and reconcile it: `landed` adopts it and advances the durable event
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
