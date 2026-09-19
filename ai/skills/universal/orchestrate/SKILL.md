---
name: orchestrate
description: >-
  Standing mode for policy-resolved, worktree-isolated Dev flow runs. It
  dispatches scoped roles, owns run records and adjudication, monitors durable
  events, and schedules a merge queue without making product or safety choices.
  Use when coordinating one or more Dev Loop lanes. Invoke as /orchestrate.
---

# Orchestrate

**Runtime assets travel with the skills.** Every executable this skill names is
vendored by `task sync:skills`, never fetched from a repository-root `scripts/`
path (harmon-devkit#974): a consumer that installed the skill has no such
directory, so a root-relative dependency installs a skill that cannot run. Two
shorthands are used below and resolve the same way in harmon-devkit's source
tree and in a consumer's flattened `.claude/skills/` one:

- `assets/<name>` — this skill's own asset, i.e. `${CLAUDE_SKILL_DIR}/assets/<name>`.
- `<package>/assets/<name>` — a sibling package's asset, i.e.
  `${CLAUDE_SKILL_DIR}/../<package>/assets/<name>`. The shared dev-flow v2
  runtime (`devflow-policy.mjs`, `validate-result-schemas.mjs`,
  `render-dev-flow.{sh,mjs}`, `dev-flow-exit.{sh,mjs}`) lives in
  `dev-flow-support/assets/`; see that package's `SKILL.md`.

A missing sibling package is a blocker, not a fallback: vendor the `universal`
category as a unit rather than resolving a runtime path some other way.

Resolve and announce policy with `dev-flow-support/assets/devflow-policy.mjs`; record resolved
rigor, rounds, breadth, roles, strategy, and disclosures in the run. That
reader operates under `schema_version = 2` and under nothing else: a legacy,
v1, mixed, or unknown `.devflow.toml` is refused with one actionable message
(`copier update` against the harmon-init release shipping the version-2
template, and hold `.skills-sync.yaml` at the last pre-v2 skills release until
it has migrated). Report that message as a blocker and start no run; never
hand-decode an older shape, invent caps, or advance the pin to get past it
(harmon-devkit#604). `assets/consumer-pin-audit.sh` is the standing check
that a repository's vendored-skill pin and its policy shape agree. Runtime
isolation is optional; its absence alone is not a dispatch blocker. Every role
still stays within its declared scope. Use one worktree and branch per lane,
record ownership, scope, dependencies, and the complete file overlap.
Before dispatching overlapping scopes, either serialize them or record the
explicit merge dependency in both lane briefs.

## Planning

Before provisioning or dispatching a slate, turn its milestone or explicit
issue list and the resolved policy into a durable plan at
`<git-common-dir>/dev-flow-v2/slates/<slate-id>/plan.json`. Resolve the common
Git directory with `git rev-parse --git-common-dir`; a linked worktree's `.git`
path is a file and is never the shared-state root. Planning is orchestrator
judgement written down, not a new autonomous planner: the schema, validator,
and append-only recompute rule make its deterministic parts checkable.
A second writer of the same `plan.json` is a blocker, not a race to lock
against.

Build and publish the plan in this order:

1. **Graph.** When `.foreman.toml` exists and the slate is milestone-backed,
   consume `task foreman:plan -- --milestone <n>` for dependencies, waves, and
   the ready set instead of reimplementing Foreman's graph. Otherwise read
   native blocked-by edges and the fixed `Blocked by:` fallback lines from
   `breakdown` §4. For an explicit issue list in a Foreman repository, include
   its containing milestone in the graph input or stop if no authoritative
   Foreman graph can cover the list.
2. **Re-verify.** Check every ready issue read-only against the live target
   tree. Record `valid`, `partial`, or `done` and a complete candidate-file
   list; issue-body line numbers are hints, never evidence. Remove `done`
   issues from dispatch waves without erasing their verified verdict.
3. **Overlap.** Compare every pair of dispatchable candidate-file lists. Record
   the complete shared-path intersection for each overlapping pair, choose
   `serialize` or `split`, and record the resulting merge dependency. A split
   also becomes the ownership fence in both lane briefs; an overlap absent
   from the plan is not safe to dispatch.
4. **Cap.** Record which dispatcher applies and the cap it actually uses. An
   interactive orchestrator uses the resolved
   `[breadth].max_parallel_agents` directly. Only when Foreman is the dispatcher
   is that policy cap intersected with `.foreman.toml`'s `max_parallel`; a
   configured Foreman limit never lowers an interactive run's cap.
5. **Project.** In a complete revision `plan`, record the resolved policy
   snapshot; re-verified issues and candidate files; pairwise overlaps and
   resolutions; waves; and lane, issue, branch, run id, and fence assignments.
   Each lane fence uses exactly the `brief.envelope.schema.json` `fence` item
   shape. Later authorized expansions append `{path, at, reason}` entries to
   that lane's `expansions` array instead of rewriting its original fence. An
   accepted expansion is a recomputation reason: before the lane edits the
   expanded path, publish a complete new revision through the candidate,
   validate, rename, and canonical-readback sequence in step 7.
6. **Emit and validate.** Write the closed record and validate it with
   `node dev-flow-support/assets/validate-result-schemas.mjs plan <plan.json>`. Refuse dispatch
   on a structural error, a broken revision digest, an incomplete overlap set,
   a graph/projection mismatch, an ownership error, or a cap violation.
   Immediately before each lane dispatch, compare the live target head with the
   last revision's `plan.base_sha`; when they differ, recompute and validate the
   plan before dispatching.
7. **Recompute after every external merge.** Re-read the new default-branch
   head, release newly unblocked dependents, rebuild waves, and repeat live
   re-verification and pairwise overlap checks. Append the next `revisions[]`
   entry with the complete new `plan` plus `seq`, `prev_digest`, `digest`, `at`,
   and `reason`, using the same canonical-JSON SHA-256 chain convention as
   `run.schema.json`; the digest covers the complete sorted-key `plan` and the
   chain fields. The last revision is current, and earlier revisions remain
   reconstructable without a second top-level projection. As the slate's single
   writer, write the complete candidate beside `plan.json`, validate that
   candidate with the `plan` kind, rename it over the canonical record, then
   validate the canonical readback. Either validation or rename failure is a
   blocker; dispatch and merge-queue mutation remain paused.

## Lane briefs

Lane briefs consume the validated plan's last revision assignments, fences,
overlap choices, and merge dependencies rather than reconstructing them from
session prose.

### File-scope fences

A file-scope fence is the closed list of paths and globs a lane may write. Derive
it from the issue's named surface, every repository test that asserts on those
files, and the consumers reported by
`assets/validator-dependency-scan.sh <path>...` for each manifest, schema, or
registry in that surface. The scan is a read-only, grep-based inventory of
consumers under `scripts/`, `ai/skills/**/assets`, `taskfiles/`, and
`Taskfile.yml`; it finds file names and hard-coded keys, not YAML/TOML scalar
values. Inspect its candidates and add the validators and tests that would
reject the lane's change. Release-please's `CHANGELOG.md` is never
lane-owned and never belongs in a fence; lockfiles are ordinary fence entries.

Across live lanes, enforce one writer per file. When an overlap is unavoidable,
name the shared file and disjoint sections in both lane briefs' overlap lists
and record the branch-update or merge dependency that serializes them. A worker
has one bounded self-expansion route: a validator or test that rejects its
change and that no other live lane touches, recorded once for that file as
`YYYY-MM-DD fence expansion: path:line[-line] — reason` in its lane report.
Verify the dated entry and line scope, reject it if another live fence owns the
file, and record the accepted expansion as a `run.json` intervention with `kind: asked`.
The Planning section owns recording the same fact in `plan.json`.
Every other expansion requires an ownership check and an attributed re-brief
before the worker edits the file.

Before evaluating the readiness gate, run
`assets/fence-check.sh --brief <rendered.md>`.
It derives the comparison base from the brief's default branch, then reports
whether both sides of every changed path are covered by the rendered envelope
fence or a labelled expansion in the envelope's `report_path`. Its advisory
refusal is visible to the orchestrator.
This pre-gate subset check is not a readiness-gate condition.

The source catalog below is the complete render contract. It deliberately lives
in this procedure rather than in the dispatched template: substituting free-form
values into a catalog inside the output would duplicate them into a Markdown
table before their intended sections.

| Placeholder | Source |
| --- | --- |
| `{{brief-envelope-json}}` | JSON serialization of the exact `brief.envelope.schema.json` fact fields; `body` is omitted from the block because the validator derives it from all Markdown outside the delimiters |
| `{{lane-name}}` | Orchestrator lane plan |
| `{{run-id}}` | Active run's `run.json` |
| `{{branch}}` | Lane plan and `git branch --show-current` |
| `{{default-branch}}` | Target repository default branch |
| `{{base-sha}}` | Lane creation record |
| `{{worktree-path}}` | `git rev-parse --show-toplevel` in the lane |
| `{{harness}}` | Selected implementer's registry harness |
| `{{report-path}}` | Nonce-scoped path under the common Git directory, or a path whose worktree exclusion the orchestrator has installed and verified |
| `{{generation}}` | Active pointer generation |
| `{{active-state-path}}` | `assets/dev-flow-monitor.sh active-path` |
| `{{record-directory}}` | Active run record directory |
| `{{policy-projection}}` | Resolved policy projection recorded at kickoff |
| `{{file-scope-fence}}` | Orchestrator's lane ownership plan |
| `{{live-lane-overlaps}}` | Orchestrator's complete live-lane overlap map |
| `{{issue-number}}` | Claimed GitHub issue number |
| `{{issue-title}}` | Fresh canonical-target `gh issue view` result |
| `{{issue-url}}` | Canonical target-repository issue URL |
| `{{claim-handoff}}` | Transaction-refreshed claim for the provisioned lane branch: authenticated comment ID, author ID, `updated_at`, expected assignees, and expected claim labels |
| `{{verified-facts-and-rulings}}` | Orchestrator verification and attributed decisions |
| `{{git-sandbox-note}}` | Harness-specific sandbox policy, or `Not applicable.` |
| `{{known-environmental-failure}}` | Verified run exception, or `None.` |
| `{{rigor}}` | Trusted policy resolution |
| `{{rigor-source}}` | Policy resolver disclosure |
| `{{challenge-cap}}` | Selected rounds policy |
| `{{review-cap}}` | Selected rounds policy |
| `{{integration-cap}}` | Selected rounds policy |
| `{{remediation-cap}}` | Selected rounds policy |
| `{{min-rounds}}` | Selected rounds policy |
| `{{wall-clock-min}}` | Selected rounds policy |
| `{{deadline}}` | Active `run.json.started_at` plus `wall_clock_min` |
| `{{max-agent-runs}}` | Selected breadth envelope |
| `{{max-parallel-agents}}` | Selected breadth envelope |
| `{{strategy}}` | Trusted policy resolution |
| `{{strategy-source}}` | Policy resolver disclosure |
| `{{role-tiers}}` | Resolved five-role tier projection |
| `{{operator-pins}}` | Attributed operator pins, or `None.` |
| `{{pr-title}}` | Orchestrator's release-title-compliant proposal |
| `{{ready-sentinel}}` | Orchestrator-generated per-lane sentinel prefix |
| `{{handoff-sentinel}}` | Orchestrator-generated draft-handoff sentinel prefix |
| `{{blocked-sentinel}}` | Orchestrator-generated per-lane sentinel prefix |
| `{{attempt-nonce}}` | Fresh nonce for this dispatch attempt |

Every lane brief MUST carry the active run identity so the lane worker can
route confidence stages through `/review` and publish a draft with v2 evidence;
the supervising orchestrator then invokes `/integrate` and retains every
finding disposition, PR-body edit, thread reply, readiness decision, and
promotion. (`retro-run-report.mjs` exit 10 `no-run-record` is the failure this
routing prevents.) The required fields are: run id, branch, generation,
active-state path, record directory, and policy projection. Without them the
lane worker falls back to the inline `task challenge` / `task review` procedure,
which produces no run record and no adjudication evidence.

Before draft publication, a confidence-stage finding uses the template's
decision handshake: the lane records a decision request and waits for a durable
orchestrator-authored disposition. With a compatible `/review`, a confirmed code
fix is performed by the fresh bounded implementer dispatched after the
orchestrator reserves its agent run. The inline fallback has no such dispatch
surface, so the orchestrator instead authorizes the original lane to apply only
the exact confirmed fixes in its recorded disposition and verifies the returned
gate/publication evidence. The post-draft handoff remains separate and transfers
integration to the supervising orchestrator.

Render `assets/lane-brief.md` for every end-to-end, PR-owning implementation lane
instead of hand-authoring a brief. Council proposal and synthesis implementers,
and bounded remediation implementers, use their schema-bound role briefs and
return the artifact or fix their dispatch requested; they do not receive this
draft-publication contract. For a PR-owning lane, the source catalog above is
the complete input contract: source every value, select the harness procedure
named by the rendered brief. Provision the lane branch/worktree, then
transactionally refresh the existing claim so its record names that exact branch.
Authenticate the refreshed claim into the handoff snapshot without transferring
its ownership.
As a render-time completeness check, scan the entire rendered file and refuse
dispatch if any unreplaced `{{name}}` token remains. This is the renderer's
check, not content validation of the opaque body; the `brief` validator checks
double-brace tokens only inside the envelope block.
Validate the rendered brief before dispatch and refuse dispatch on any failure:
`node dev-flow-support/assets/validate-result-schemas.mjs brief "$brief_path"`.
Place the per-attempt report under the common Git directory, or install and
verify its worktree exclusion before dispatch; an assertion that it is excluded
is not evidence. Preserve its nonce-scoped sentinels. Prompts sent after dispatch
refer to that reporting contract indirectly and never quote a sentinel value,
because old pane output must not satisfy a later attempt.

## PR-open confirmation

Before promoting a lane's PR, confirm the lane produced v2 evidence
appropriate to its topology and resolved policy for the lane's active
run ID. Each enabled confidence stage (resolved cap ≥ 1) must have its
own evidence — adjudication records from `/review`, not merely a kickoff
marker — and a disabled stage (cap 0) must have its authenticated
disabled-stage verdict; a single verdict never covers an enabled stage.
A lane dispatched under the fork topology or without a vendored
`/review` skill uses the inline fallback by design and produces no v2
evidence; the orchestrator accepts that limitation and does not require
evidence the procedure cannot produce. `retro-run-report.mjs` exit 10
(`no-run-record`) is the diagnostic for a lane that was expected to
produce evidence and did not; when the condition fails and the skill
path is available for the lane's topology, the routing failed and the
lane must be re-run before the PR is promoted.

The maintainer-facing ready report is the last message about a promoted PR,
not the first one after promotion. **Invariant: the ready report is sent
only for a `POST-PROMOTION-CLOSED` event that names the promotion event id
the watcher armed on, with zero activity rows in that window, and only
after one re-read taken after the close shows the same head, the same
readiness fingerprint, and every check still concluded green; any other
observation (a different promotion id, any activity row, any changed
value, any indeterminate read) withdraws the report and re-arms.** The
re-read uses the same mechanisms `AGENTS.md` § Readiness gate names for the
promotion-time check (`headRefOid`/`isDraft`, required CI status, and
`readiness-gate.sh fingerprint`); promotion itself is never reported as
readiness, and a status sent during the watch instead reads "promoted at
T, post-promotion watch until T+15", never "ready". Matching the vendored
`/integrate` skill's own handling of an invalidated promotion
(`.claude/skills/integrate/SKILL.md` step 6): withdrawing runs
`gh pr ready --undo` and confirms the PR is draft on the current head
before deciding whether to re-verify or escalate. The mechanism that
satisfies this invariant — window arming, activity/close correlation by
promotion event id, retry on an indeterminate read — belongs to
`assets/lane-watch.sh`; this section states only what must be true before
the report is sent, never the ordering or per-endpoint steps the watcher
uses to get there.
This maintainer-facing report is distinct from § Persistent supervision's
internal per-lane ledger entry ("a ready PR is reported"), which is
orchestrator bookkeeping, not the maintainer-facing message this rule defines.

If the orchestrator reverses its own promotion (`gh pr ready --undo`, for any
reason, including mid-watch), the withdrawal is announced before anything
else in the next maintainer-facing message — "#n is no longer ready: `<reason>`; back to draft on `<head>`" — ahead of any other status in that same message.

## Implementer selection

Select implementers only from
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
`assets/dev-flow-monitor.sh reserve-agent-run` with a deterministic dispatch
event and the resolved `[breadth].max_agent_runs`. Confidence finders and
fallbacks spend the independent rounds envelope and never this implementer
budget. The monitor pins the total implementer ceiling on the first reservation
and durably accounts every slot under the active-run lock. A crash after
reservation spends the slot; an exact event re-arm adopts it without spending
twice. A changed or exhausted budget blocks before dispatch.

## Persistent supervision

Watching is the standing mode, not a one-shot step. Use the harness's
session-lifetime persistent monitor primitive—never a background shell subject
to an ordinary command timeout—to poll fresh lane-agent and PR state and emit
only transitions (`idle`, `done`, `blocked`, `unknown`, and PR deltas). If it
exits before the overall run reaches a terminal outcome, re-arm it immediately;
never interpret monitor termination as human cancellation. If no persistent
primitive is available, block instead of silently falling back to occasional
manual polling.

Use `assets/lane-watch.sh` for that polling. Harness monitor primitives may run
their command under a non-Bash shell, so always invoke the file as
`bash <skill-dir>/assets/lane-watch.sh --state-file <run-dir>/lane-watch.state --registry
<kickoff-registry-snapshot> <deadline> <lane:branch:nonce:owner/repo>...`;
never paste its loop inline. Keep the state file across re-arms so reported
sentinels and post-promotion activity remain deduplicated. The watcher bounds
every `herdr` and `gh` read, prefers each lane's `.lane-report.md` sentinel,
tags pane-only fallback results, and watches reviews plus top-level and inline
comments for 15 minutes after a draft becomes ready. When a lane's
post-promotion window's promotion event cannot be resolved before that
window's own deadline passes, the watcher emits
`POST-PROMOTION-INDETERMINATE <lane>: #<pr>` instead of silently abandoning
the window — the event means only that the promotion epoch could not be
confirmed in time; that path also clears the lane's tracked `PR` state as it
tears the window down, so the very next observation — the watcher's own next
poll, or a fresh process restarted against the same `--state-file` — sees
the still-promoted PR as newly observed and re-arms a fresh window on its
own, which is what makes restarting with the same state file a genuine
retry rather than a no-op. Keep the registry argument
bound to the immutable kickoff snapshot across every re-arm. It only reports
events; the orchestrator remains responsible for every action. The watcher-owned
`lane-watch.state` is separate from the run's canonical `monitor.json`; never
pass that JSON monitor state to `--state-file`.

The watcher's own restart durability does not, by itself, make the
orchestrator's reporting durable: `POST-PROMOTION-ACTIVITY` and
`POST-PROMOTION-CLOSED` are lines on the watcher's stdout, consumed by a
separate orchestrator process, and the § PR-open confirmation gate depends
on the orchestrator having durably seen every activity line for the
*current* window — never merely on what its own live stdout stream has shown
since its own last restart. An orchestrator restart mid-window must not
silently default to "no activity seen"; confirm that against durable state,
either by re-deriving what happened over the window's `[since,until]`
directly from the same GitHub activity sources `lane-watch.sh` itself polls,
or by maintaining its own durable log of every `POST-PROMOTION-ACTIVITY` /
`POST-PROMOTION-CLOSED` line it has actually processed.

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
`assets/dev-flow-monitor.sh state-path --run-id <run-id>` returns the canonical
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
