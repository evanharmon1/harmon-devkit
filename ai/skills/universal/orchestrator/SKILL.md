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
rigor, rounds, breadth, roles, strategy, and disclosures in the run. That
reader operates under `schema_version = 2` and under nothing else: a legacy,
v1, mixed, or unknown `.devflow.toml` is refused with one actionable message
(`copier update` against the harmon-init release shipping the version-2
template, and hold `.skills-sync.yaml` at the last pre-v2 skills release until
it has migrated). Report that message as a blocker and start no run; never
hand-decode an older shape, invent caps, or advance the pin to get past it
(harmon-devkit#604). `scripts/consumer-pin-audit.sh` is the standing check
that a repository's vendored-skill pin and its policy shape agree. Dispatch
only roles whose harness can enforce their registry write boundary: a judgment
role receives a result-only channel with no ambient workspace, shell, git, gh,
or write credential, otherwise the run blocks. Use one worktree and branch per
lane, record ownership, scope, dependencies, and the complete file overlap.
Before dispatching overlapping scopes, either serialize them or record the
explicit merge dependency in both lane briefs. Select implementers only from
the resolved `[stage.implement].pool`, registry role eligibility, and resolved
family/harness preferences; council dispatches also enforce its
`distinct_families` requirement. Enforce one
writer per feature branch. A lane can commit only its lane branch; the feature
owner alone assembles selected lanes, then records the included/discarded lanes
and canonical SHA in that assembly's `run.json` stage transition before pushing
the feature branch. Under council with `synthesis = true`, dispatch one fresh
implementer with the ordered source proposals and accept its artifact only when
`result.implementer.payload.synthesis_of` names those proposal identities in
that same order; record every proposal's selection outcome in the assembly.
Reject a lane that requests feature-branch write authority.

Immediately before every implementer invocation—initial lanes, council
proposals and synthesis, and remediation—the feature owner calls
`scripts/dev-flow-monitor.sh reserve-agent-run` with a deterministic dispatch
event and the resolved `[breadth].max_agent_runs`. Confidence finders and
fallbacks spend the independent rounds envelope and never this implementer
budget. The monitor pins the total implementer ceiling on the first reservation
and durably accounts every slot under the active-run lock. A crash after
reservation spends the slot; an exact event re-arm adopts it without spending
twice. A changed or exhausted budget blocks before dispatch.

Feature-owner authority comes from an orchestrator-installed capability
boundary that is never exposed to lane agents; the monitor's `--writer` value
is only a checked assertion inside that boundary, not a credential a lane may
supply. If the harness cannot prevent a lane from invoking feature-owner
assembly, reservation, or push capabilities, parallel dispatch is unavailable
and the run blocks.

## Persistent supervision

Watching is the standing mode, not a one-shot step. Use the harness's
session-lifetime persistent monitor primitive—never a background shell subject
to an ordinary command timeout—to poll fresh lane-agent and PR state and emit
only transitions (`idle`, `done`, `blocked`, `unknown`, and PR deltas). If it
exits before the overall run reaches a terminal outcome, re-arm it immediately;
never interpret monitor termination as human cancellation. If no persistent
primitive is available, block instead of silently falling back to occasional
manual polling.

Every emitted transition terminates in a recorded action: idle reads and
adjudicates the lane status (including any unsupported claim that the user was
asked); done validates and assembles or records a blocker; blocked/unknown
surfaces the evidence and stops or re-briefs within authority; a ready PR is
reported with merge-queue externalities; a dirty PR returns to its owning lane;
and an external merge releases dependents, recomputes the queue, and rechecks
stacked branches. Keep a visible per-lane ledger of assignment, fresh state,
last progress, and next action. Hand off the run record before primary-session
context exhaustion so a fresh driver can re-arm the same monitor.

Resolve the shared run directory with `git rev-parse --git-common-dir`, never by
appending to a worktree's `.git` path (which is a file in linked worktrees).
`scripts/dev-flow-monitor.sh state-path --run-id <run-id>` returns the canonical
`<git-common-dir>/dev-flow-v2/runs/<run-id>/monitor.json` path. Keep
the schema-valid `run.json` beside it. Resolve the branch's shared active pointer
with `active-path`, and activate a new run by compare-and-swap from the prior
generation while passing the kickoff-pinned registry revision; the resulting
active pointer is the run's immutable registry binding. Activation also binds
each run ID to exactly one branch before any branch-specific pointer can write
its canonical monitor ledger. Every `reserve` and
`reconcile` supplies that canonical active path, run ID, branch, and generation,
and derives the canonical monitor-state path from the run ID; a superseded run
blocks even when it presents the same expected head. Before assembly, push, or
comment, first reserve an event/action/expected-head in monitor state. An
assembly reservation also persists the exact integrated and discarded lane
identities, and reconciliation requires the landed observation to reproduce
that selection before the run transition is written. Never reserve or replay a
merge.
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

Treat resolved `rounds.wall_clock_min` as a ceiling for the whole run, measured
from `run.started_at`, not as a fresh allowance for each stage or resumed
session. Read a fresh trusted clock immediately before every dispatch,
reservation, replay, external action, and merge-queue mutation. Once the
deadline is reached, record the capped transition and render its blocker before
stopping. The sole external action still authorized after expiry is to reserve,
publish, and reconcile that exact terminal blocker through the monitor; forbid
all dispatches, code pushes, ordinary comment writes, and merge-queue mutations.
A cached time check or a check performed only after the write cannot enforce
this ceiling.

Bound parallel implementers by `[breadth]` and strategy and heavy local stages
by host capacity. Maintain a merge queue from complete file lists, pairwise
overlap, dependencies, stage, and re-verification cost. Recommend
oldest-terminal/highest-cost first and disclose externalities. Product, scope,
consent, and safety decisions stop for a human; re-scoping requires two traces.
