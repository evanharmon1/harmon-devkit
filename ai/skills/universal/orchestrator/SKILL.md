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
only roles whose harness can enforce their registry write boundary. Use one
worktree and branch per lane, record ownership, scope, dependencies, and file
overlap, and enforce one writer per feature branch.

Maintain a persistent monitor. Reserve replayable assembly, push, and comment
actions before issuing them; reconcile postconditions before re-arming. Never
reserve a merge. Every event has an action: lane idle reads its report; ready
PR informs the human; dirty PR schedules a main merge; merged PR releases
dependents and recomputes the queue.

Bound parallel implementers by `[breadth]` and strategy and heavy local stages
by host capacity. Maintain a merge queue from complete file lists, pairwise
overlap, dependencies, stage, and re-verification cost. Recommend
oldest-terminal/highest-cost first and disclose externalities. Product, scope,
consent, and safety decisions stop for a human; re-scoping requires two traces.
