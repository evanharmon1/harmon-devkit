# Groom report — evanharmon1/harmon-devkit

_Generated: 2026-10-29 13:10 UTC_

## Stats

- Open issues: 620
- Close candidates: 20
- Decisions needed: 30
- High priority: 104
- Pre-audit triage pass: ran

## What to do next

1. Review 20 close candidate(s) below.
1. Answer 30 decision(s) below.
1. Review 24 spec-worthy theme proposal(s) below.
1. Review 63 process finding(s) below.
1. Resolve 393 conformance defect(s) below.

## Close now

| # | Title | Verdict | Priority | Group | Status | Reason / Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| #667 | (standardize-repo): Accept date-named ADRs in the decisions audit | CLOSE-done | p2 | standardization/decisions | PENDING | Date-name convention, renamed-numbered-record guidance and exact date-only-log regression all shipped; latest issue comment searched the wrong test file. — _Evidence:_ Merged PR #1295 fix(standardize-repo): sweep catalog and mode-guide drift against the template (9c13e258d355e98ca3ad0d9e60109fa559b711d1); scripts/test-skills.sh:8110-8141 tests a date-named unrelated record plus README and an empty-log negative control; standards-catalog.md:61,75,89 and mode-update.md:124 document convention/EQUIV. |
| #898 | (ci): Add test:dev-flow-monitor to build.yml test matrix | CLOSE-done | p2 | delivery/ci-parity | PENDING | CI now invokes the shared project test target, which includes dev-flow-monitor; a hand-maintained workflow matrix entry is no longer needed. — _Evidence:_ Taskfile.yml:382-408 test deps includes test:dev-flow-monitor; .github/workflows/build.yml:204 runs task test; scripts/test-verify-ci-parity.sh:44-59 enforces that project test call; adoption commit d18b8e93 fix(template): update harmon-init to v5.7.2 (#1453). |
| #525 | (dev-flow): Refuse truncated live label pages in the metadata fallback vocabulary | CLOSE-done | p2 | track-work/metadata | PENDING | Fallback vocabulary reader now refuses a full 1000-label page with exit 2 and accepts shorter listings. — _Evidence:_ ai/skills/universal/track-work/assets/check-issue-metadata.sh:197-209; scripts/test-track-work.sh:3060-3069; current immutable audit snapshot |
| #553 | (track-work): Support host-qualified metadata checks | CLOSE-done | p2 | track-work/host-binding | PENDING | Host-qualified metadata preflight and remote binding are implemented, with personal/org and HTTPS/SSH regression coverage. — _Evidence:_ Merged PR #1324 fix(track-work): accept a host-qualified repository in the metadata preflight; check-issue-metadata.sh:230-278; scripts/test-track-work.sh:897-1023 |
| #1231 | (track-work): Require human and umbrella on collector titles | CLOSE-done | p2 | tracker/collectors | PENDING | Metadata preflight now requires both human and umbrella on HUMAN/QA collector titles, with missing-label and success cases. — _Evidence:_ Merged PR #1304 feat(triage): decide the human label at triage and at filing; track-work/assets/check-issue-metadata.sh:969-974; scripts/test-track-work.sh:1455-1469,3149-3157 |
| #411 | (shepherd): Shepherd carry: freshness gate refuses evidence check | CLOSE-done | p1 | integration/review-safety | PENDING | The rebuilt carry retains the original cycle and rechecks its evidence instead of trusting timestamp freshness; the old clock-skew and same-second snapshot comparison no longer exists. — _Evidence:_ ai/skills/universal/integrate/assets/check-codex-cloud-review.sh:3501-3528 preserves original cycle; :1270 verify_carried_attestation re-derives proof; merged PR #1163 feat(integrate): carry a clean verdict across a base catch-up when the change is provably unchanged. |
| #669 | (shepherd): Write the claim-released record when releasing the label | CLOSE-obsolete | p2 | integration/lifecycle | PENDING | The lifecycle now intentionally separates active-work label removal at handoff from terminal claim release; keeping assignee/claim record is explicit policy, so writing a release record here would be wrong. — _Evidence:_ ai/skills/universal/integrate/SKILL.md:2930-2940 explicitly preserves assignee/durable claim until terminal release and forbids substituting full claim release.; merged PR #1592 feat(integrate): mark an issue needs-review while its PR awaits human review documents the handoff split. |
| #1184 | (integrate): Support BSD base64 decode on macOS in trusted-registry.sh | CLOSE-obsolete | p3 | integration/review-lifecycle | PENDING | The reported macOS incompatibility is disproved on macOS 15.7.4; the issue identifies no older-version reproduction, and its existing failure branch is already clear. — _Evidence:_ ai/skills/universal/integrate/assets/trusted-registry.sh:67-70; macOS 15.7.4 (24G517), native /usr/bin/base64 -h advertises -D/-d/--decode; -d sample returns 0 and expected JSON, invalid input returns 1 |
| #1697 | (integrate): Give catch-up fixtures enough time under parallel load | CLOSE-done | p2 | integration/evidence-and-gates | PENDING | Merged fixture changes give ordinary success reads 30 seconds while preserving explicit zero-wait and slow-read assertions; the merged PR records full verification. — _Evidence:_ scripts/test-integrate-update-branch.sh:147; :430; :450; merged PR #1699 fix(template): update harmon-init to v5.13.3 (14753921267d80d80f6c6ec9ca3fc4cdb1389334) |
| #1698 | (integrate): Keep readiness carry fixtures parseable on Bash 3.2 | CLOSE-done | p2 | integration/evidence-and-gates | PENDING | Merged fixture extracts the quoted Python heredoc outside substitution, then reads its file; positive/negative carry and complete flag probes remain active. — _Evidence:_ scripts/test-integrate-readiness.sh:5563; :5574; :5588; :5727; merged PR #1699 fix(template): update harmon-init to v5.13.3 (14753921267d80d80f6c6ec9ca3fc4cdb1389334) |
| #1042 | (review): evidence_comments entries are written with null comment_id and actor_id after reconcile | CLOSE-done | p2 | review/evidence-publication | PENDING | Current evidence schema rejects null identities; publisher adopts authenticated IDs into the validated run chain and readiness validates that chain. — _Evidence:_ ai/schemas/run.schema.json:226; ai/skills/universal/review/assets/post-evidence.sh:197; test-post-evidence.sh:175,295; integrate/assets/readiness-gate.sh:2345; merged PR #1411 feat(review): post the dev-flow-v2-evidence marker through a helper |
| #1156 | (orchestrate): digest evidence comments over the body as posted, and record the digest the harvester recomputes | CLOSE-done | p2 | orchestration/delegation-contract | PENDING | Shipped evidence writer hashes the fetched comment body, verifies exact reservation/readback equality, and registers that digest for the harvester; mismatch fails closed. — _Evidence:_ ai/skills/universal/review/assets/post-evidence.sh:172-205; immutable commit 629fb498 feat(review): post the dev-flow-v2-evidence marker through a helper (#1411) |
| #1246 | (orchestrate): Make PR post-promotion wait window configurable in devflow.toml | CLOSE-obsolete | p3 | orchestration/merge-queue | PENDING | The adopted lifecycle explicitly removes fixed post-promotion windows; making the retired window configurable is no longer the requested design. — _Evidence:_ AGENTS.md:365-366 requires ownership until merge/close with no fixed window; merged PR #1617 docs(dev-flow): record the PR lifecycle, handoff check and merge queue; #1603 (orchestrate): Keep one merge-ready queue head, park the rest as drafts, and watch promoted PRs until merge implements the replacement |
| #774 | (dev-flow-stats): apply registry trust before index selection | CLOSE-done | p1 | records/trust | PENDING | Current code authenticates candidates at their write times in ascending ID order before selecting one, so an unauthorized lower-ID index no longer shadows a legitimate index; a regression pins the case. — _Evidence:_ ai/skills/universal/retro/assets/dev-flow-stats.mjs:859-883; retro/assets/test-dev-flow-stats.sh:6376; merged PR #797 feat(agent-registry): add the trusted-orchestrator actor allowlist, pinned per write (5f1ebb83). |
| #1161 | (dev-flow-stats): count remediation pushes against the remediation cap in run trajectories | CLOSE-done | p2 | records/metrics | PENDING | The requested invariant shipped using integration re-entry remediation records: trajectories expose push receipts and cap, and the retro prints pushes spent against that cap with regression coverage. — _Evidence:_ ai/skills/universal/retro/assets/dev-flow-stats.mjs:3408-3411 remediation_pushes; retro-run-report.mjs:1118 and :1318; scripts/test-retro-run-report.sh remediation real-loader coverage; merged PR #1569 fix(retro): measure remediation pushes and findings by finder; stop citing closed issues. |
| #1133 | (agents): integrator §7 assembly template hardcodes status completed, defeating the consecutive-16 blocked report | CLOSE-done | p2 | agents/integration | PENDING | Integrator builder now accepts and preserves the selected status, including the third consecutive transient-read blocker; regression tests exercise completed and blocked assembly. — _Evidence:_ ai/agents/integrator.md:837-838,1253-1280; scripts/test-skills.sh:4367-4386; merged PR #1458 fix(integrate): detect and undo a ready-for-review flip no readiness gate produced, against the run record (50312d8d) fixes integrator builder status in integration R1 |
| #342 | (skills): Decide this repo's use_skills_sync posture — sync:skills cannot run against its own symlinked skills | CLOSE-done | p2 | workflow/skills-sync | PENDING | The third proposed posture is now explicitly documented: retain template-rendered sync machinery, use live-source dogfood links, and deliberately refuse self-vendoring. — _Evidence:_ ai/skills/README.md:120; .copier-answers.yml:48 |
| #605 | (skills): Decide whether third-party skills (e.g. Matt Pocock's) get their own skill category | CLOSE-done | p3 | workflow/skill-authoring | PENDING | Third-party author categories are established and actively vendored/dogfooded, including Matt Pocock and Compound Engineering attribution. — _Evidence:_ ai/skills/README.md:31,145; merged PR #660 feat(skills): dogfood the matt-pocock skills via .agents/skills symlinks; merged PR #1196 chore(config): vendor matt-pocock skills and expand claude allowlist |
| #1134 | (dev-flow): render-dev-flow bounds integration adjudication rounds by the Codex-cycle cap although integration_round counts integrator passes | CLOSE-done | p1 | dev-flow/cycle-accounting | PENDING | Integration cap validation now counts charged Codex cycles independently of integrator pass ordinals. — _Evidence:_ ai/skills/universal/dev-flow-support/assets/render-dev-flow.mjs:835-863; merged PR #1511 fix(dev-flow): authorize extra charged integration cycles (2026-10-17), immutable commit e6f0a7c4. |
| #1475 | (claim): Retry the post-publication liveness read and let an exact re-run resume | CLOSE-dup-of-#1194 — (claim): Re-read post-publication state over a bounded settle window before reporting indeterminate | p2 | claim/reconciliation | PENDING | Both issues request the same bounded post-publication liveness retry and exact-transaction resume despite pre-existing assignee ownership; keep the earlier open issue as survivor. — _Evidence:_ #1194 (claim): Re-read post-publication state over a bounded settle window before reporting indeterminate has the same two triggers and criteria; claim/assets/claim-transaction.sh:740,994 confirms the shared unfixed path. |

## Milestones

- widen Standardize-repo fleet runs (health: open: 39, closed: 5, oldest open issue: #150 — (standardize-repo): Orphan sweep drowns in .app bundle internals (94 days old)) (#1685 — fix(standardize-repo): finish the split-jobs vocabulary and make gate reachability leaf-based, #1707 — fix(standardize-repo): finish the rigor-label retirement and domain-extension steps) — Optional bounded runbook/catalog follow-ups; keep their existing priorities and do not make them new fleet blockers.
- create Integration evidence and handoff integrity (health: new milestone proposal) (#404 — (shepherd): Readiness gate can pass on revoked reaction evidence — bind trigger reactions into the fingerprint, #762 — (shepherd): readiness-gate.sh never rechecks activity newer than the integrator result, #1140 — (integrate): readiness gate reads only the first 100 closingIssuesReferences, so a body claiming more issues fails closing-linkage permanently, #1141 — (integrate): readiness gate does not re-verify closing linkage or base across the promotion window, #1142 — (integrate): the closing-target issue lookup classifies any object without pull_request as an issue without checking its identity, #1152 — fix(integrate): apply the charged/exempt pair and sum checks to finder_cycles[], #1177 — (integrate): Hold the readiness gate until every bot reviewer's findings are answered, #1257 — (integrate): re-gate a run whose promotion was reversed and whose head then moved, #1433 — (integrate): Refuse a registered evidence comment whose first line is not the canonical dev-flow-v2-evidence marker, #1635 — (integrate): Restrict checker-only readiness to exact trigger comments and empty reviews, #1680 — (integrate): Reconcile legacy deferred checklists before handoff, #1703 — (integrate): Prove claim-record lineage before releasing claim labels at handoff) — Group final proof coverage, identity and settlement work separately from the closed Integration convergence milestone.
- create Integration wait and recovery reliability (health: new milestone proposal) (#415 — (shepherd): Watch loops can stall forever on a zombie check run whose parent workflow run already concluded, #467 — (integrate): Preflight the gh login before posting Codex triggers — unauthorized triggers present as a reviewer outage, #472 — (shepherd): Document the workflow_dispatch fallback when GitHub never creates the pull_request check suite, #501 — (shepherd): Probe mergeStateStatus before reserving a Codex cycle — BEHIND wastes a full review cycle, #534 — (shepherd): Own cloud-review wait loop in shepherd skill, #651 — (shepherd): Diagnose a DIRTY head before waiting on absent checks, #1111 — (integrate): Ship a polling asset for the stage's waits instead of hand-rolled monitors) — Group observable waiting, trigger preflight and diagnosed recovery while preserving distinct failure criteria.
- widen Dev flow v2 (health: open: 131, closed: 89, oldest open issue: #468 — (shepherd): Extend the gate-verdict marker rule from pushes to all gate-chained writes (commits included) (74 days old)) (#517 — (dev-flow): Dev loop: resume yielded gate sessions instead of, #529 — (dev-flow): Make background gate runs survive the periodic SIGTERM kills, #642 — (claim): Surface cross-repo publication blockers before review, #959 — (review): run the reviewer outside the candidate checkout so candidate instructions cannot steer it, #1365 — (review): give Codex envelope mode a schema-enforcing, approval-never invocation, #1379 — (review): pass prior-round finding records to envelope-mode finders, #1383 — (review): bind envelope-mode governing inputs and the review tree to the captured head, #1405 — (review): handle a generation change mid-publication and run ids that do not encode their issue, #1412 — (review): harden post-evidence.sh publication against hung calls, a full comment scan and listing lag, #1428 — (review): build or verify the published evidence projection from retained round evidence) — These are core v2 execution/evidence contracts; retain separate acceptance criteria and existing trust-boundary parent rather than starting another initiative. Include yielded-session identity, termination classification, and producer-publication revalidation as executable-stage integration cases under the already-milestoned extraction issue.
- widen Orchestrator resilience (health: open: 16, closed: 27, oldest open issue: #1159 — (integrate): make integrator passes immutable and their Codex verdicts self-authenticating (36 days old)) (#1072 — (orchestrator): pre-authorise P2/P3 dispositions in lane briefs so lanes stop only on P0/P1 or a cap, #1093 — (orchestrator): Resume lanes and reviewers after a session usage limit, #1122 — (orchestrator): Delegate complete bounded remediation units, #1169 — (orchestrator): Verify a Codex prompt started a turn on the expected model before treating it as delivered, #1181 — (orchestrate): Ship a lane-watch that returns on an idle settle ending in a question, #1241 — (orchestrate): suppress the survey and size the window for Claude lanes, #1278 — (orchestrate): Let a lane continue past an empty confidence round without waiting for the orchestrator, #1288 — (orchestrate): Park supervision while only a human can move the run, and let lane-watch exit on the first terminal event, #1290 — (orchestrate): Let Antigravity lanes run their gates without approvals, confirm prompt delivery, and stay in their own lane, #1335 — (orchestrate): Report lane heads from git rev-parse and verify them before acting, #1435 — (orchestrate): Have the orchestrator attest the lane's model and effort in the brief for harnesses with no self-readable status line, #1445 — (dev-flow-support): let a solo run invalidate a stale unadjudicated pass instead of wedging the round, #1473 — (dev-flow-support): Reject non-canonical run ids at plan, brief and run validation, #1538 — (dev-flow-stats): Bound run lookup for IDs outside the canonical run-issue-slug format, #1539 — (dev-flow plan schema): Let a later revision withdraw an accepted fence expansion, #1540 — (orchestrate): Check other sessions' open PRs before accepting a fence expansion, #1553 — (orchestrate): document a Codex lane launch that can commit from a linked worktree, #1564 — (orchestrate): harden lane-watch heartbeats, prompt episodes and sentinels for edge cases, #1568 — (dev-flow-support): refuse pre-token readers and re-check slate-lock ownership inside the write mutex, #1574 — (lane brief): Hold a confidence round's fix push until the orchestrator records the round, #1575 — (lane brief): Name the configured finder slot and finding-id format for each confidence stage, #1576 — (orchestrate): make lane provisioning resumable, identifier-safe, re-briefing and remote-aware, #1578 — (orchestrate): give lane-watch an ownership lease and live spec reload, #1579 — (orchestrate): Record a lane's stage transitions before its finder runs, so a pass is never dated before its stage, #1651 — (orchestrate): Handle empty active-pointer directories on Bash 3.2, #1656 — (orchestrate): Add a lane teardown step for merged lanes, with no per-lane approval, #1679 — (dev-flow-support): Record a maintainer-requested catch-up on a promoted run) — Use the existing resilience milestone for the remaining dispatch, stop/resume, ownership, and watcher contracts instead of creating another orchestration umbrella; sequence structured waiting/authority and runnable launch fixes ahead of watcher refinements. Extend the existing resilience milestone with immutable-run recovery, identity validation, bounded evidence lookup, fence withdrawal, ownership checks and post-lane lifecycle evidence; these are the remaining ways a resumed orchestrator loses truthful state. This is an optional scope expansion for maintainer selection, not new blockers for the active slate; existing assignments and explicitly excluded follow-ups remain unchanged.

## Parent issues

- #1111 — (integrate): Ship a polling asset for the stage's waits instead of hand-rolled monitors: #534 — (shepherd): Own cloud-review wait loop in shepherd skill
- (new) (integrate): Define integrator dispatch and result contracts: #1277 — (integrator): Report reviewer summaries, repeated declined comments and unsolicited finder comments without recording them as findings, #1279 — (integrate): Tell the orchestrator to dispatch each role agent on a model of its resolved tier, #1280 — (validate): Fail a role result whose producer tier departs from the resolved tier without a disclosure, #1283 — (integrate): Ship an integrator brief template that stops duplicate reads and verbatim reports, #1284 — (integrate): Add a command that assembles and validates the integrator result
- #559 — (agents): Preserve delegated gate ownership through completion: #615 — (implementer): direct delegated agents to run repo gates serially, not concurrently, #657 — (implementer): Keep driving a pending shepherd cycle instead of ending the turn
- #630 — (dev-flow): Replace prompt-sized policy with executable stages: #642 — (claim): Surface cross-repo publication blockers before review
- #1058 — (retro): Finish the retro reconstruction follow-ups deferred from PR #991 and #962: #986 — (retro): tighten discovery token boundaries and evaluate every same-tier body token before selecting

## Spec-worthy themes

### Tracker structural semantics and lifecycle transitions

- Recommended vehicle: adr
- Reason: Define ordinary issues, parent trackers, action collectors and QA queues consistently; retain the separate tested mutation mechanism. Recommend approving an ADR anchored in the existing structure issue, not a new umbrella.
- Candidate issues:
  - #1693 — (skills): Align groom, triage and track-work on epics, collectors, and where each issue belongs
  - #627 — (track-work): Define post-merge criterion close transition
  - #883 — (track-work): A closing parent strands its native sub-issues open
  - #1227 — (triage): Reconcile collector items against source follow-up lines
  - #1229 — (breakdown): Cite new collectors by number from the chunks they serve
  - #1233 — (track-work): Bind collector scope reads and handle a last moved criterion
  - #1678 — (track-work): Route verification steps to (QA) and actions to (HUMAN) collectors
  - #1228 — (groom): Apply an approved move of human follow-ups to their collector
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Headless tracker read/write boundary

- Recommended vehicle: adr
- Reason: Specify permitted reads and output sinks once, with separate triage/groom adapters and deterministic report-only automation. Approve the boundary design before an unattended worker implementation.
- Candidate issues:
  - #483 — (triage): Sandbox the headless worker beyond permission rules
  - #1037 — (groom): bind the headless audit worker's reads to the checkout and the resolved repository
  - #1087 — (triage): Run the report half of triage weekly from a workflow, keeping label writes supervised
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### What evidence may certify a review cycle?

- Recommended vehicle: adr
- Reason: Resolve head binding, unbound settlement, additional reviewers and fallback identity together. Approve the ADR before another output parser; existing three-form contract remains authoritative.
- Candidate issues:
  - #1117 — feat(integrate): accept the Codex summary Completed row as terminal-clean under the head-binding invariants
  - #1127 — (integrate): settled unbound badged comments never certify a head, so the cycle ends by escalation instead of clean
  - #1177 — (integrate): Hold the readiness gate until every bot reviewer's findings are answered
  - #1180 — (integrate): Fall back to a Claude review after two incomplete Codex attempts
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### One gate-to-write contract across workflow stages

- Recommended vehicle: bmad
- Reason: Specify exit/timeout propagation, exact-SHA refspec portability, upstream repair and one shared evidence interface, with failure scenarios implemented as fixtures. Approve a shared design spec without merging the distinct issues.
- Candidate issues:
  - #468 — (shepherd): Extend the gate-verdict marker rule from pushes to all gate-chained writes (commits included)
  - #496 — (shepherd): Unbraced $sha in push refspecs is mangled by zsh history modifiers
  - #516 — (shepherd): Establish PR-head upstream after the first exact-SHA push
  - #645 — (shepherd): Unify gated push protocols across shepherd and gauntlet
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### Authenticated review evidence across checker-only and dispatched paths

- Recommended vehicle: adr
- Reason: Define authentic inputs, retained history across path transitions, and permissible terminal-record reopening without fabricating producer evidence. Approve the ADR before changing both gate and schema.
- Candidate issues:
  - #1630 — (integrate): Preserve checker-only cycle history when dispatching a later cycle
  - #724 — (devflow): require registry-validated policy before computing an exit
  - #1257 — (integrate): re-gate a run whose promotion was reversed and whose head then moved
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### First-adoption evidence before trust configuration merges

- Recommended vehicle: adr
- Reason: Choose the preferred supported publication path and narrow intentional-withholding exception; these are alternatives, not literal duplicates. Approve one ADR that preserves authentication boundaries.
- Candidate issues:
  - #1491 — (integrate): Accept a terminal run record for first-adoption runs that intentionally publish no issue evidence
  - #1536 — (integrate): Publish PR-hosted run evidence on first-adoption runs so /retro can measure them
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Integrator dispatch and result contracts

- Recommended vehicle: bmad
- Reason: Specify rendered briefs, typed observations, actual producer identity, and one validated result assembler before independent changes diverge. Approve an interface design under the proposed parent.
- Candidate issues:
  - #1277 — (integrator): Report reviewer summaries, repeated declined comments and unsolicited finder comments without recording them as findings
  - #1279 — (integrate): Tell the orchestrator to dispatch each role agent on a model of its resolved tier
  - #1280 — (validate): Fail a role result whose producer tier departs from the resolved tier without a disclosure
  - #1283 — (integrate): Ship an integrator brief template that stops duplicate reads and verbatim reports
  - #1284 — (integrate): Add a command that assembles and validates the integrator result
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### Trusted review inputs and evidence ownership

- Recommended vehicle: adr
- Reason: Settle trusted executable/instruction roots and captured-head ownership once, then retain independent implementation tasks. Approve the ADR before adding per-reader exceptions.
- Candidate issues:
  - #791 — (review): Execute the round-push broker from the trusted merge-base closure
  - #793 — (review): Execute exit evaluation from the trusted merge-base closure
  - #959 — (review): run the reviewer outside the candidate checkout so candidate instructions cannot steer it
  - #1383 — (review): bind envelope-mode governing inputs and the review tree to the captured head
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Durable human transitions and supervisor acknowledgements

- Recommended vehicle: bmad
- Reason: Preserve the recorded maintainer decision for directives/stage epochs; distinguish acknowledgement from progress and define bounded operator transitions without another orchestration framework.
- Candidate issues:
  - #1008 — (review loop): Make human transitions terminal and enforceable
  - #1009 — (review budget): Stop scope accretion at the round-two checkpoint
  - #1023 — (orchestrator): plan.json attributable operator override for policy/dispatcher changes across revisions
  - #608 — (herdr delegation): Add a supervised staged-agent handoff procedure
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### Lane authority and machine-readable stop/resume contract

- Recommended vehicle: adr
- Reason: These issues change who may continue, when a lane must stop, and which durable state proves a round is recorded. Resolve a single invariant for intermediate waiting, empty-round advancement, standing dispositions, and stage-before-finder ordering before implementing separate signaling mechanisms.
- Candidate issues:
  - #1072 — (orchestrator): pre-authorise P2/P3 dispositions in lane briefs so lanes stop only on P0/P1 or a cap
  - #1122 — (orchestrator): Delegate complete bounded remediation units
  - #1181 — (orchestrate): Ship a lane-watch that returns on an idle settle ending in a question
  - #1278 — (orchestrate): Let a lane continue past an empty confidence round without waiting for the orchestrator
  - #1288 — (orchestrate): Park supervision while only a human can move the run, and let lane-watch exit on the first terminal event
  - #1297 — (orchestrate): Signal lane state through a structured status file instead of a matched report heading
  - #1574 — (lane brief): Hold a confidence round's fix push until the orchestrator records the round
  - #1579 — (orchestrate): Record a lane's stage transitions before its finder runs, so a pass is never dated before its stage
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Authenticated run evidence through every entry path

- Recommended vehicle: bmad
- Reason: Digest hashing is shipped, but canonical publication, producer/slot/head identity, stage ordering, and bot-draft takeover still have distinct gaps. Specify one end-to-end evidence contract and integration fixtures rather than allowing each skill to invent a handoff.
- Candidate issues:
  - #1202 — (orchestrate): name the challenge/review envelope persistence path in the lane brief Codex section
  - #1335 — (orchestrate): Report lane heads from git rev-parse and verify them before acting
  - #1395 — (orchestrate): Settle the cloud-lane P2 findings deferred from PR #1385
  - #1416 — (orchestrate): make run-record init and canonical evidence posting the default at every rigor
  - #1514 — (orchestrate): Render the PR policy disclosure and post evidence only through the shipped helper
  - #1541 — (orchestrate): Name the finder as the pass envelope's producer in the lane brief
  - #1573 — (orchestrate): Record the implement transition when a lane is dispatched
  - #1574 — (lane brief): Hold a confidence round's fix push until the orchestrator records the round
  - #1575 — (lane brief): Name the configured finder slot and finding-id format for each confidence stage
  - #1579 — (orchestrate): Record a lane's stage transitions before its finder runs, so a pass is never dated before its stage
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### Versioned run evidence contracts across canonical schemas, legacy comments and retained records

- Recommended vehicle: adr
- Reason: The current schema, legacy harvester and retained-record path have different compatibility and validation guarantees. Receipt fields shipped, while exit fixtures, schema chain fields, strict receipts and repository-wide current-marker discovery remain incomplete; an explicit migration contract prevents another layer of per-reader exceptions.
- Candidate issues:
  - #727 — (devflow): define a schema for run receipts and slot failures
  - #738 — (schemas): add seq/digest/prev_digest to run-record append-only arrays
  - #755 — (schemas): chain-protect run-record promotion contents
  - #757 — (dev-flow-stats): validate harvested records against run.schema.json
  - #777 — (schemas): validate chronology for pr/outcome chain timestamps
  - #913 — (stats): Require --receipts in dev-flow-stats validation
  - #977 — (dev-flow-stats): make the replay producer emit canonical receipts with authenticated chronology
  - #995 — (dev-flow-stats): repository-wide metrics and replay should discover current-marker runs and consume a record directory
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Operator-controlled wall-clock extensions and measured budget calibration

- Recommended vehicle: adr
- Reason: The default deep budget has grown to 2880 minutes, but paused time, extensions and proving a calibrated allowance remain distinct unresolved requirements. Record the policy choice and evidence shape before adding another timer mechanism.
- Candidate issues:
  - #920 — (devflow): Decide pause-aware wall clock or extension protocol
  - #1074 — (devflow-policy): derive the deep wall clock from the resolved caps, not a 480-minute constant
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Delegated gate lifecycle and evidence ownership

- Recommended vehicle: bmad
- Reason: Repeated reports span short gates, long background review waits, interruption/resume, duplicate starts and final handoffs. Specify one owner and explicit running/adopted/terminal states before duplicating more prose.
- Candidate issues:
  - #305 — (implementer): Backgrounding the exit gate makes §5 and §7 unsatisfiable — a subagent has no next turn to collect it
  - #386 — (agents): Record that subagent briefs must demand foreground gate runs
  - #559 — (agents): Preserve delegated gate ownership through completion
  - #615 — (implementer): direct delegated agents to run repo gates serially, not concurrently
  - #657 — (implementer): Keep driving a pending shepherd cycle instead of ending the turn
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### What authorizes a push when gate execution is reused or retried

- Recommended vehicle: adr
- Reason: These proposals change commit/gate ordering, exception policy and trust in lane logs. Record the exact evidence and authority boundary once, keeping strict gate results distinguishable from environmental exceptions.
- Candidate issues:
  - #717 — (implement): Rerun the one failing gate task alone twice instead of the full verify
  - #1359 — (implement): Commit each round's fixes before the long verify run, push only after it passes
  - #1414 — (implement): accept a lane's SHA-bound GATE-EXIT and skip the orchestrator's redundant verify
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Claim transaction completion and recovery contract

- Recommended vehicle: bmad
- Reason: Read-after-write lag, model-less record vocabulary and exact-record idempotence share one transaction boundary; the newline implementation already shipped, so plan the surviving criteria rather than rebuilding it.
- Candidate issues:
  - #572 — (claim): Retry the record re-read before exiting 6 on comment lag
  - #580 — (claim): Make the record template and helper agree on model-label n/a
  - #584 — (claim): Tolerate a trailing newline in the published claim record
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### Reviewer independence and connector mutation authority

- Recommended vehicle: adr
- Reason: Separate authenticated actor identity, allowed reviewer mutations and integration recovery; reviewer write capability is an account-level unknown while inline draft-undo has an attributable maintainer decision.
- Candidate issues:
  - #201 — (skills): Identity checks must name their authority — the same 'trust the payload' defect appeared three times in one PR
  - #298 — (dev-flow): The cloud reviewer authored a commit on the branch it was reviewing
  - #509 — (dev-flow): Codex connector: remove the draft-promotion failure class
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Scoped gate execution and reuse of verification evidence

- Recommended vehicle: adr
- Reason: Quick code gates, changed-scope execution, lock coordination, clean baselines and prose-only evidence reuse overlap but are not duplicates. One contract must define changed-input selection, unmatched-path fallback, retained full-verification obligations and baseline validity. Keep all currently standalone follow-ups outside active milestones unless the maintainer explicitly schedules them. Record one ADR before implementing either changed-scope selector; reply "design scoped gate contract". Retain separate acceptance criteria for concurrency control, baseline policy and inert prose corrections.
- Candidate issues:
  - #676 — (verify): Take test:shepherd-codex off the verify critical path
  - #887 — (workflow): Clarify verification for docs-only corrections
  - #1021 — (tasks): add a quick per-round gate between check and verify for code rounds
  - #1068 — (verify): serialise task verify across parallel lanes and add a changed-scope gate
  - #1110 — (dev-flow): Establish a clean gate baseline before a session starts work
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Portable runtime packaging and consumer execution proof

- Recommended vehicle: bmad
- Reason: The relocation is merged, but versioned closure identity, atomic install, trusted reader layout handling, executable reachability checks and hermetic smoke fixtures remain separate unfulfilled contracts. Respect the deliberate split of the invocation guard rather than repeating regex hardening. Design the manifest/install/proof boundary around existing dev-flow-support; decide test-corpus distribution and repo-owned review-runner exemptions first. Reply "design runtime closure contract".
- Candidate issues:
  - #877 — (dev-flow runtime): runtime manifest, atomic skills-sync install, offline verification, and /orchestrate preflight — residue after #974
  - #1099 — (dev-flow): mechanical guard that fails task verify when a vendored skill or agent invokes a repository-root scripts/ path
  - #1113 — fix(dev-flow-support): cover every closure reader layout in the fixtures and refuse symlinked candidates
  - #1114 — test(skills): make the AC-5 vendored sweep hermetic and decide how vendored suites get their fixture corpus
- How to respond: Agree to draft spec via bmad, or decline to keep as individual issues.

### One revision-bound operational record and report lifecycle

- Recommended vehicle: adr
- Reason: Timestamp capture, HTML artifacts, rescue-intervention reporting and persistent retro reports should project the same operational record instead of introducing independent narratives. HTML remains optional and rescue classification must preserve expected approvals. Use the existing run schema, writer and renderer to define authoritative revision, durable location, publication state and intervention semantics; reply "record operational projection ADR". Keep currently standalone items unscheduled.
- Candidate issues:
  - #712 — (session-flow): Record a timestamp in kickoff, claim, and implement so wall-clock time per stage can be computed
  - #882 — (dev-flow): Add Claude Code artifacts (HTML reports) to the dev flow
  - #1010 — (agent UX): Report human interventions as workflow failures
  - #1046 — consider outputting and saving a report as part of the retro skill. Perhaps as a way to make orchestration runs more visible and observible and measurable and improvable. In contrast to issues, milestones, prs, etc orchestration sessions should have some kind of artifact to track and measure and improve. Similar general method to the groom skill report.
  - #1119 — (dev-flow): Generate all status views from one run record
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Acceptance ownership and claim continuity across partial delivery

- Recommended vehicle: adr
- Reason: Composed claiming, explicit completion, planned-slice retention and acceptance mapping share the boundary between current work, remaining work and authorized transfers; none is literally equivalent to another. Document one acceptance/claim lifecycle using existing issue and run records, preserving accountable QA transfers and claim ownership; reply "design acceptance and claim contract".
- Candidate issues:
  - #659 — (wrap): Keep the claim across planned multi-slice deliveries
  - #672 — (claim): Provide an autonomous-mode path for the claim writes
  - #817 — (claim): make the claim step's write non-optional in the implement flow
  - #1120 — (dev-flow): Reconcile acceptance scope before implementation
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### One versioned run-evidence and event-order contract

- Recommended vehicle: adr
- Reason: Policy shape, per-round verdict identity, remediation ordering, schema integrity and plan revision checks currently each reconstruct overlapping facts. Define authoritative event order, ownership, schema version and input identity once, then test each consumer against that contract. This is a design theme only; preserve the explicit decision that hardening remains outside the universal-record-production epic and retain standalone deferred follow-ups outside active milestones. Approve a contract ADR and an acceptance-case matrix before implementation; respond "design evidence/event contract". Do not mass-attach these issues to an active milestone.
- Candidate issues:
  - #1158 — (dev-flow): one policy.json contract for the run record, read identically by the readiness gate renderer and the retro harvester
  - #1369 — feat(dev-flow): persist per-round exit verdicts so split adjudications can be bound to their candidate
  - #1404 — feat(dev-flow): evaluate remediation pushes in one chronological pass to make the fixing ceiling airtight
  - #1466 — (dev-flow): Reject six malformed result and run-record shapes the validator still accepts
  - #1624 — fix(dev-flow-support): bind recorded policy projections to their run in lane-init and solo-init
  - #1640 — fix(dev-flow-support): tighten plan merge-queue checks across revisions, cap counting and pr binding
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Portable and deterministic verification fixtures

- Recommended vehicle: adr
- Reason: GNU dialect, enclosing worktrees, wall-clock budget races, heredoc execution and non-Linux descriptor refusals create different gate answers across hosts. Specify fixture-owned clocks and repositories, platform capability branches, and stderr failure behavior, then retain separate small fixes. These issues overlap in testing policy, not literal scope. Approve a fixture portability/determinism ADR with platform and stress-test coverage; respond "design fixture contract". Keep the existing individual fixes separately schedulable and do not move deferred work into active milestones.
- Candidate issues:
  - #1136 — fix(test): GNU-only date -d breaks test-integrate-codex.sh on macOS
  - #1155 — test(integrate): test-integrate-codex.sh exited 2 once under load
  - #1236 — (tests): Make test-integrate-codex pass inside a nested .worktrees checkout
  - #1554 — (retro tests): fail test-dev-flow-stats when its fixture heredoc writes to stderr
  - #1705 — (tests): Make test-integrate-codex and test-inline-record deterministic under host load
  - #1718 — (retro): test-retro-run-report's ENOENT race cases fail on macOS, where descriptor containment is refused
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

### Branch identity, push authority and recovery under the existing trust-boundary parent

- Recommended vehicle: adr
- Reason: Keep the existing native parent and distinct children. Agree one destination identity/ownership invariant before implementing atomic authorization and exact-target recovery; approve a design clarification, not a new parent.
- Candidate issues:
  - #1056 — (review): Land the current-head review follow-ups deferred from PR #768 as one trust-boundary body of work
  - #783 — (devflow): Bind recovered pushes to the named remote ref
  - #788 — (devflow): Canonicalize active branch identities
  - #794 — (devflow): Make feature push authorization atomic with active-run ownership
- How to respond: Agree to draft spec via adr, or decline to keep as individual issues.

## Decisions

### Top five

- #280 — (agents): C — Identifier denylist decision + shipped-content sweep + lint:leakage guard [AGENT+HUMAN] — For #280 (agents): C — Identifier denylist decision + shipped-content sweep + lint:leakage guard [AGENT+HUMAN], which identifiers should the shipped-content guard forbid?
  - Recommendation: Approve a concrete denylist before implementation, retaining intentionally public identifiers; reply with the forbidden identifiers and any precise allowlisted contexts.
  - Why ranked in top five: High (P1) priority, blocks 0 downstream issue(s), 85 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #298 — (dev-flow): The cloud reviewer authored a commit on the branch it was reviewing — Should reviewer-authored commits remain prohibited, with a maintainer investigation of connector write capabilities and explicit integration handling?
  - Recommendation: Prefer prohibiting reviewer-authored commits; respond “prohibit and investigate” to retain this issue as a HUMAN capability investigation plus a scoped integration check, or state the intended allowed behavior.
  - Why ranked in top five: High (P1) priority, blocks 0 downstream issue(s), 85 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #716 — (verify): make the verify gate faster and lighter — shellcheck memory, load flakiness, parallel-lane contention — Should gate optimization now use bounded shellcheck analysis and explicit concurrency limits, or first split the largest suites?
  - Recommendation: Prefer splitting the largest suites and documenting a worker bound, retain full verification, then measure memory and wall clock; respond approve split-first or name the preferred alternative before implementation.
  - Why ranked in top five: High (P1) priority, blocks 0 downstream issue(s), 57 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #724 — (devflow): require registry-validated policy before computing an exit — Should exit computation require a registry-validated resolved-policy receipt rather than accepting raw policy with registry checks silently omitted?
  - Recommendation: Choose a bound resolved-policy receipt shared by all callers, with unknown-finder rejection fixtures; respond receipt or name an explicit alternative calling convention.
  - Why ranked in top five: High (P1) priority, blocks 0 downstream issue(s), 57 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #254 — (agents): Verify-agents/verify-skills approximate YAML in awk, so 'valid' can mean something a loader rejects — For #254 (agents): Verify-agents/verify-skills approximate YAML in awk, should both guards adopt a required YAML parser or formally retain their limited awk boundary?
  - Recommendation: Prefer a required YAML parser in provisioned validation, with a named missing-tool diagnostic; reply adopt parser or retain boundary and document that choice for both guards.
  - Why ranked in top five: Medium (P2) priority, blocks 0 downstream issue(s), 87 days old.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

### Next ten

- #484 — (triage): Persist inapplicable-axis attestations durably — Accept explicit axis:none labels as the durable replacement and close this retired attestation-store proposal?
  - Recommendation: Close as obsolete because the helper now refuses --inapplicable and persists none labels; respond approve #484 obsolete or name a remaining store requirement.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #564 — (gauntlet): Validate guarded-push inputs before running full gates — Should the issue be revised around the current broker-owned gate contract, dropping caller-marker reuse while retaining bounded transport preflight?
  - Recommendation: Approve revising the criteria to retain broker-owned gates and implement bounded transport preflight; respond approve-revise or specify the alternative evidence design.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #579 — (claim): Clear or report pre-record claim markers on close — Should close-time release clear unowned claim markers or report them with a distinct status?
  - Recommendation: Prefer report with a distinct exit and named residue, preserving ownership safety; respond report or clear to settle the requested policy.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #627 — (track-work): Define post-merge criterion close transition — Which approved transition should handle criteria that become true only after merge?
  - Recommendation: Prefer a Refs delivery followed by explicit post-merge verification, ordinary open-issue ticking and completed closure; respond approve that transition or specify an alternative.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #671 — (triage): Surface apparently completed open issues for review — Move the remaining supervised triage precision review to the standing QA collector and close the delivered implementation issue?
  - Recommendation: Prefer moving the supervised review to this repository QA collector, retaining provenance, then closing; respond approve move-and-close or keep the original issue open.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #717 — (implement): Rerun the one failing gate task alone twice instead of the full verify — For #717 (implement): Rerun the one failing gate task alone twice instead of the full verify, should the proposed four-condition exception be adopted or rejected?
  - Recommendation: Prefer retaining the green-gate requirement and fixing/serializing known flakes; reply retain strict gate or approve an exact amended exception and authoritative allowlist location.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #855 — (implement): ship a brief template that carries gate bounds, the stop-at-draft rule, and the proposal-only clause — For #855 (implement): ship a brief template that carries gate bounds, the stop-at-draft rule, and the proposal-only clause, may its remaining per-repository gate-bound confirmation move to the HUMAN/QA collector before closing?
  - Recommendation: Prefer moving the named gate-bound confirmation to the standing HUMAN/QA collector, recording the shipped CI criteria, then closing; reply move follow-up and close or retain here.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #883 — (track-work): A closing parent strands its native sub-issues open — Should same-PR children carry their own acceptance criteria, and should closing-parent checks warn about unnamed open children?
  - Recommendation: Prefer child-owned criteria plus an advisory guard naming each open child so authors explicitly close only finished children; respond approve or choose parent-only criteria.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #920 — (devflow): Decide pause-aware wall clock or extension protocol — Should externally paused time stop the clock, or should strict elapsed time use recorded operator deadline extensions?
  - Recommendation: Prefer strict elapsed time plus an explicit maintainer-only extension record with old/new deadline, reason and actor; respond approve extension protocol, or choose pause-aware accounting with its evidence signal.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #1015 — (skills): Add a groom skill: verify, dispose, regroup, and record decisions across a backlog — Accept the documented supervised devkit run in place of the harmon-init first-run criterion, or retain that exact validation target?
  - Recommendation: Prefer move the remaining target-specific supervised check to the standing QA collector and close the shipped implementation issue; respond approve move-and-close or require harmon-init validation.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

### Remainder by area

#### dev-flow/result-contract

- #1171 — schema: the codex-cloud mirror in finder_cycles[] may contradict codex_cycle — Should the redundant codex-cloud entry be removed from finder_cycles, or required to equal codex_cycle completely?
  - Recommendation: Prefer removing the redundant codex-cloud mirror with a documented producer migration; respond "remove mirror" or "enforce full equality" before implementation.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### groom/publishing

- #1088 — (groom): Decide and implement a durable destination for the groom report — Should committed repository reports become the default for future groom runs, or should a durable hosted-report destination be designed?
  - Recommendation: Use the committed report branch already chosen for this audit. Prefer making that simple destination the default unless hosted browsing is required; respond make committed reports the default, or name the hosting requirement. This asks about future policy, not permission for this report.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### groom/structure

- #1205 — (groom): Let a spec-worthy theme name a planning vehicle the repository actually uses — Add a neutral design-document vehicle, make the vocabulary configurable, or retain the closed list?
  - Recommendation: Prefer a validated design-doc neutral value alongside bmad/adr as the smallest portable extension; respond approve design-doc or choose repository configuration.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### orchestrate/authority

- #1214 — (dev-loop): Decide whether a delegate lane may run a default-branch catch-up merge — May a delegate ever merge the default branch into its own feature branch when its consumer brief grants it?
  - Recommendation: Prefer reserving catch-up merges to the orchestrator, consistent with server catch-up policy and the lane brief; respond "orchestrator only" or explicitly authorize consumer-granted lane catch-ups, then align policy and tests.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### orchestration/contracts-and-records

- #1523 — (orchestrate): ship the tooling a restarted orchestrator needs instead of scratchpad helpers — May the shared HUMAN mid-slate restart exercise move to one standing QA entry, then this shipped tooling parent close?
  - Recommendation: Approve one QA entry shared with the writer delivery issue and close this parent after reconciling its five shipped child checkboxes; respond approve QA transfer, or keep the parent until the exercise succeeds.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### orchestration/durable-state

- #1296 — (orchestrate): Keep orchestrator state in the Git common directory and ship tested run-record and plan writers — May the remaining HUMAN restart-from-common-directory exercise move to the standing QA collector, together with the same check retained by its companion tooling parent, so this shipped writer issue can close?
  - Recommendation: Approve one QA entry for the mid-slate restart exercise and close this delivery issue; respond approve QA transfer, or keep it open until the restart exercise succeeds.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### orchestration/remote-lanes

- #1210 — (orchestrate): Run lanes as Claude Code cloud sessions that Herdr can start, attach to, and watch — May the remaining HUMAN end-to-end confirmation move to the standing QA collector so the shipped cloud-lane issue can close?
  - Recommendation: Approve transferring the named end-to-end confirmation to QA and closing this delivery issue; respond approve QA transfer, or keep it here until you accept the multi-launch evidence.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### orchestration/supervision

- #1288 — (orchestrate): Park supervision while only a human can move the run, and let lane-watch exit on the first terminal event — Should parking stop only local-lane polling while PR review/CI/base monitoring continues until merge, or should lifetime PR ownership policy be changed?
  - Recommendation: Keep PR lifetime monitoring, narrow parking to waits with no possible automated transition, and retain terminal-event mode as implementation work; respond narrow parking, or explicitly choose to revise lifetime ownership.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### policy/registry

- #1378 — (agent-registry): reconcile copilot-cli harness roles with its registered challenge/review finders, and enforce one authority — For #1378 (agent-registry): reconcile copilot-cli harness roles with its registered challenge/review finders, and enforce one authority, should harness roles constrain every finder role?
  - Recommendation: Prefer harness roles as the common authorization boundary, add challenger/reviewer to Copilot where intended, and enforce the cross-check in shared validation; reply approve harness authority or choose finder authority.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### review/deferred-findings

- #908 — (dev-flow): Decide whether deferred findings need a dedicated state/memory store (sidecar.md) beyond GitHub issues — Should an additional deferred-finding memory store be designed, or should the current run-record and GitHub projection contract remain authoritative?
  - Recommendation: Prefer the existing stores until a concrete missing recovery or query use case is identified; respond keep current stores to close this speculative decision, or name the missing use case to scope it.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### runtime-distribution

- #1114 — test(skills): make the AC-5 vendored sweep hermetic and decide how vendored suites get their fixture corpus — Should consumer packages omit authoring-only test suites or include their complete fixture corpus?
  - Recommendation: Keep authoring-only suites and corpus in source CI, omit them from consumer packages through an explicit manifest, and hermetically bound the smoke sweep; reply "source-only authoring tests" or "ship tests plus corpus".
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### workflow-learning

- #978 — (ci): Create a skill to create decision records — Does the existing domain-modeling ADR workflow satisfy this request, or is a broader dedicated decision-record skill required?
  - Recommendation: Use the existing domain-modeling skill and close this idea as redundant; reply "existing ADR workflow is sufficient" or describe the missing non-domain decision-record requirements.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #1012 — (ci): Consider adding the built-in Claude Code simplify skill to the dev workflow after implement — Should a narrowly scoped opt-in simplify pilot be evaluated after implementation, with all existing gates retained?
  - Recommendation: Run an opt-in pilot before changing default stage order; reply "pilot simplify" or "decline simplify", and replace the empty criterion with the chosen evaluation outcome.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

#### workflow-naming

- #921 — (dev-flow): Rename the plan-approved strategy to say who approves (plan-ask, plan-gated, plan-then-approve) — Should plan-approved be renamed to plan-ask, with a documented compatibility/migration plan?
  - Recommendation: Prefer plan-ask for explicit approval semantics; reply "rename to plan-ask" or provide the chosen alternative, then scope the compatibility change.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

- #922 — (dev-flow): Decide whether to rename the council strategy to market — Should the council strategy retain its current name or be renamed to market?
  - Recommendation: Retain council unless its selection semantics change; reply "keep council and close the naming question" or specify the intended market semantics.
  - How to respond: Reply "agree" to accept recommendation, "decline" to reject, or specify an alternative.
  - Status: PENDING

## Completed this run

None this run.

## Process findings

| Finding | Recommended action |
| --- | --- |
| A completion check searched the wrong test file although the exact date-named ADR fixtures shipped. #667 (standardize-repo): Accept date-named ADRs in the decisions audit | Approve the code-backed CI criterion tick and closure; search behavior/fixtures across the repository before inferring missing coverage from one filename. (How to respond: reply "agree" to apply remediation, or "decline") |
| The issue still describes a hand-maintained CI list although shared test calls and a parity guard exist. #1109 (ci): Audit what task verify runs against what CI runs, and define what gates a merge | Approve a narrow body refresh separating delivered mechanisms from the remaining exception, required-check and runner-budget audits; keep the issue open. (How to respond: reply "agree" to apply remediation, or "decline") |
| The body retains after-wave reconcile timing superseded by its comment and ADR. #1669 (standardize-repo): Run the GitHub-side reconcile phase in every mode, probing in lanes and writing from the parent | Approve a body correction to per-repository post-merge writes serialized per owner before implementation; this does not authorize any security-setting change. (How to respond: reply "agree" to apply remediation, or "decline") |
| Several issues use PR-style title prefixes and older issues have malformed, long or truncated titles. #1685 fix(standardize-repo): finish the split-jobs vocabulary and make gate reachability leaf-based; #1707 fix(standardize-repo): finish the rigor-label retirement and domain-extension steps; #1609 fix(track-work): refuse wrong-case ratings before filing and tighten file-review-finding follow-ups; #1612 fix(dev-flow-support): skip needs-review cleanup for replayed events older than the label | Use the report conformance rows for supervised retitle/body-normalization plans; preserve original wording and exclude bot dashboards. Approve a bounded title pass, not blind truncation. (How to respond: reply "agree" to apply remediation, or "decline") |
| Checked criteria and active implementation evidence do not establish main-branch delivery. #1537 (standardize-repo): Read fleet-run rulings from one versioned decisions file; #1605 (integrate): Read check runs through a GitHub App installation token; #1635 (integrate): Restrict checker-only readiness to exact trigger comments and empty reviews; #1682 (orchestrate, integrate): Run pollers as bounded background passes, and fail loudly when gh or herdr is unreachable; #1704 (orchestrate): Enforce working and in-flight ceilings at dispatch, not in the static plan validator | Retain these issues and their claims; recheck merge state plus current default-branch code before closure. Respond retain active work. (How to respond: reply "agree" to apply remediation, or "decline") |
| A maintainer decision about assignment-based trust is already recorded, while current release-claim still implements the old trust rule. #975 (track-work): Stop accepting assignment as proof of write access | Schedule the already-chosen collaborator-permission API implementation; do not ask the maintainer to decide again. (How to respond: reply "agree" to apply remediation, or "decline") |
| Shipped fixes retain unchecked acceptance criteria, preventing the guarded completed-close path. #553 (track-work): Support host-qualified metadata checks; #1231 (track-work): Require human and umbrella on collector titles; #1697 (integrate): Give catch-up fixtures enough time under parallel load; #1698 (integrate): Keep readiness carry fixtures parseable on Bash 3.2 | Approve evidence-backed track-work verification/ticks first, then the corresponding closures; future mixed update/fix PRs should enumerate completed issue scopes. (How to respond: reply "agree" to apply remediation, or "decline") |
| Substantial subsets shipped, but bundled test/fidelity or evidence-contract obligations remain. #1034 (groom): fix report and dry-run fidelity — bot-owned rows, label PLAN detail, refusal and pty test coverage; #1035 (groom): persist subagent process findings through the join with --process-findings; #1332 (integrate): Harden the integration exit engine and readiness record checks after #1272 | Approve criterion-level evidence and partial-completion bookkeeping; retain each issue with its exact remainder instead of claiming the whole parent is done. (How to respond: reply "agree" to apply remediation, or "decline") |
| Human-only tracker parents can resemble completed implementation follow-ups while their children remain unfinished. #1047 (track-work): Host-qualify every GitHub write path so a wrong host or missing scope is refused before writing; #1048 (track-work): Make Verify blocks fail closed — one authoring rule for no-output and planning-profile checks; #1049 (triage): Settle the deferred findings from the triage v1 review (PR #480 and #523) | Evaluate parent/collector kind and live children before interpreting those flags; fold the correction into the existing structural-model work rather than creating another umbrella. (How to respond: reply "agree" to apply remediation, or "decline") |
| A receipt-guard follow-up grew to thirteen comment items crossing parser, storage, host, binary-trust and portability concerns. #1562 (track-work): harden the receipt guard for relationship flags, org issue types and stale receipts; #1556 (track-work): cover gh api issue creation in the receipt guard | Before claiming, reconcile comments into explicit criteria and split bounded PR-sized work without losing provenance; resolve the documented alias limitation against the sibling issue. (How to respond: reply "agree" to apply remediation, or "decline") |
| The groom scan does not project native parent/sub-issue structure even though regrouping proposals depend on it. #1693 (skills): Align groom, triage and track-work on epics, collectors, and where each issue belongs | Keep relationship GET reads as a preflight for approved links and implement durable structural projection under the existing issue. Do not create competing parent homes. (How to respond: reply "agree" to apply remediation, or "decline") |
| Completed checkboxes coexist with a broader unresolved promotion investigation; repeated self-fix summaries obscure observations. #276 (shepherd): Something promotes drafts out of the readiness gate's control, 9+ times in one session | Approve criteria rewritten around attribution/prevention still owed, and evidence-only observation reporting; do not close from the checked list alone. (How to respond: reply "agree" to apply remediation, or "decline") |
| A title is truncated and loses the state/head predicate it originally described. #419 (shepherd): Shepherd check: carry acceptance ignores .state and | Approve a concise retitle restoring the missing predicate, preserving the original issue meaning. (How to respond: reply "agree" to apply remediation, or "decline") |
| Retired gauntlet/shepherd/root-script paths and obsolete line numbers obscure current remaining behavior. | Approve one bounded body/Verify-path refresh to current integrate/review/implement/retro assets and Taskfile targets; never close merely because a retired file disappeared. (How to respond: reply "agree" to apply remediation, or "decline") |
| Partial integration fixes have accumulated without a reliable criterion-level record of the remainder. #808 (dev-flow): attribute remediation loops to the findings they answer; #949 (integrate): Finder_cycles validation and gate coverage gaps (#804 deferred); #976 (integrate): Propagate the integrate-codex rename to its consumers; #1121 (integrate): Run CI and review concurrently and batch fixes | Have track-work tick only currently verified criteria and state the exact remainder before dispatch, including comment-added criteria. (How to respond: reply "agree" to apply remediation, or "decline") |
| A portability premise lacks a named failing supported-platform reproduction and contradicts the tested native host. #1184 (integrate): Support BSD base64 decode on macOS in trusted-registry.sh | Approve obsolete closure, or provide a named older supported release and failing native invocation. The report records macOS 15.7.4 evidence, not a claim about every BSD variant. (How to respond: reply "agree" to apply remediation, or "decline") |
| Advisory-reviewer configuration evolved from automatic detection toward unified finder policy in a later maintainer comment. #1584 feat(integrate): request advisory Greptile reviews while draft and never gate on them | Coordinate the recorded contract with existing reviewer-policy work before implementation; retain the issue rather than infer duplicate or obsolete scope. (How to respond: reply "agree" to apply remediation, or "decline") |
| The title claims approval on-request, while later session evidence and the current guide establish approval never for the command-running reviewer. #1366 (review): local Codex review passes run with approval on-request, so reviewed content can request unsandboxed commands | Approve a retitle to the remaining controlled reviewed-diff escalation probe; preserve historical plain-exec evidence and the actual test obligation. (How to respond: reply "agree" to apply remediation, or "decline") |
| Textual blocker sentences name PRs that have already merged. #1006 (orchestrator): plan.json overlap surface should include each lane's accepted fence expansions; #1023 (orchestrator): plan.json attributable operator override for policy/dispatcher changes across revisions | Approve removing the stale blocker statements while retaining provenance; use live issue dependencies for the remaining blocking work. (How to respond: reply "agree" to apply remediation, or "decline") |
| Title-only or historically retitled requests lack a checkable implementation contract. #878 (dev-flow): Add Greptile to the supported review providers; #980 (dev-loop): Have the PR review agent post a mermaid diagram and an illustrative image for each PR | Supply scope and observable acceptance criteria before arming these issues; respond with the intended users, surfaces, behavior, and verification. (How to respond: reply "agree" to apply remediation, or "decline") |
| PR-reference candidate indexes can include cross-repository coincidences. #908 (dev-flow): Decide whether deferred findings need a dedicated state/memory store (sidecar.md) beyond GitHub issues | Retain repository qualification and inspect actual PR bodies plus current behavior; do not treat a numeric match as proof. (How to respond: reply "agree" to apply remediation, or "decline") |
| The user chose a committed report branch for this audit; a permanent cross-repository publication policy remains a separate issue. #1088 (groom): Decide and implement a durable destination for the groom report | Use this audit branch now. To settle the general issue, respond make committed reports the default or name a durable HTML store; do not ask again where this current report should go. (How to respond: reply "agree" to apply remediation, or "decline") |
| Shipped delivery issues retain human-only verification and duplicate restart follow-ups: #1210 (orchestrate): Run lanes as Claude Code cloud sessions that Herdr can start, attach to, and watch; #1296 (orchestrate): Keep orchestrator state in the Git common directory and ship tested run-record and plan writers; #1523 (orchestrate): ship the tooling a restarted orchestrator needs instead of scratchpad helpers. | Approve one standing QA entry for the common-directory restart exercise shared by the two writer/tooling issues and one entry for cloud end-to-end confirmation, reconcile completed child criteria, then close the delivered parents; respond approve QA transfer, or name which source must stay open. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1246 (orchestrate): Make PR post-promotion wait window configurable in devflow.toml requests configuration for a fixed watch window that adopted AGENTS.md policy explicitly removes; #1603 (orchestrate): Keep one merge-ready queue head, park the rest as drafts, and watch promoted PRs until merge is the unfinished replacement. | Approve CLOSE-obsolete for the configurable-window issue and keep the replacement parent until all four already-split children merge; do not restore a configurable timer. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1395 (orchestrate): Settle the cloud-lane P2 findings deferred from PR #1385 lists seven findings in its body while comments expand it to fourteen; merged PR #1465 settled only 4, 7 and 12. | Approve a track-work body reconciliation that enumerates all fourteen, records merged evidence against the three settled items, and leaves the remaining eleven unchecked; preserve the single follow-up issue rather than filing duplicates. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1288 (orchestrate): Park supervision while only a human can move the run, and let lane-watch exit on the first terminal event proposes stopping all human-wait supervision, conflicting with the later lifetime PR-watch policy. | Choose narrow parking: stop local lane polling only when no automated state can change, while keeping PR review/CI/base watching until merge; otherwise explicitly authorize a policy revision before implementation. (How to respond: reply "agree" to apply remediation, or "decline") |
| Partial merged mechanics risk masking unfinished parent behavior: #1076 (orchestrator): archive the lane report into the run directory and prune active state on teardown still lacks lane-report archiving, #1299 (orchestrate): Revise the plan only when a base move touches a live fence or closes a slate issue still mandates every-merge full recomputation, and #1603 (orchestrate): Keep one merge-ready queue head, park the rest as drafts, and watch promoted PRs until merge still has an open lifetime-watch implementation. | Keep these issues open and update each acceptance checklist only from its remaining behavior, citing the partial merged PRs; do not close from matching titles or the presence of helper files. (How to respond: reply "agree" to apply remediation, or "decline") |
| Issue #727 (devflow): define a schema for run receipts and slot failures still states canonical receipts are absent, despite merged PR #1000; the exit-input/fixture obligation remains unproven. | Approve a track-work body refresh that credits the shipped schema decision and isolates the remaining exit input/fixture contract; keep #977 (dev-flow-stats): make the replay producer emit canonical receipts with authenticated chronology as the replay producer child, rather than closing either issue from the schema PR alone. (How to respond: reply "agree" to apply remediation, or "decline") |
| Issue #1074 (devflow-policy): derive the deep wall clock from the resolved caps, not a 480-minute constant still names a 480-minute deep ceiling while audited main sets 2880 and the constant alternative leaves the derived-schema criterion ambiguous. | Respond retain constant or derive budgets; then update the issue body to the 2880 baseline, state the measurement evidence required, and preserve the human next-run proof until supplied. (How to respond: reply "agree" to apply remediation, or "decline") |
| Many records/policy follow-ups cite retired root scripts paths; implementation now lives in dev-flow-support, retro, review or orchestrate skill assets. | Approve a documentation-only tracker refresh through track-work that maps every affected body/Verify command to its current skill asset and Taskfile target; do not close issues merely because the old path vanished. (How to respond: reply "agree" to apply remediation, or "decline") |
| The merged-PR candidate index lists issue references, so incidental fixes are missed: #774 (dev-flow-stats): apply registry trust before index selection shipped in PR #797 and #1161 (dev-flow-stats): count remediation pushes against the remediation cap in run trajectories shipped in PR #1569 without closing those issues. | Approve the two evidence-backed CLOSE-done rows, and keep the groom verification step that searches current behavior and file history beyond referenced PR candidates. (How to respond: reply "agree" to apply remediation, or "decline") |
| Checked acceptance criteria on #1682 (orchestrate, integrate): Run pollers as bounded background passes, and fail loudly when gh or herdr is unreachable and #1704 (orchestrate): Enforce working and in-flight ceilings at dispatch, not in the static plan validator describe active branch work while the audited default branch still lacks it. | Keep both open and preserve their active claims/delivery lifecycle; have completion-candidate tooling require merged-default-branch evidence before recommending closure. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1133 (agents): integrator §7 assembly template hardcodes status completed, defeating the consecutive-16 blocked report is still open after merged PR #1458 fix(integrate): detect and undo a ready-for-review flip no readiness gate produced, against the run record supplied a status-preserving builder and regressions. | Approve its CLOSE-done disposition; retain file and merged-PR evidence in the closure rather than treating the older deferred status as current. (How to respond: reply "agree" to apply remediation, or "decline") |
| #855 (implement): ship a brief template that carries gate bounds, the stop-at-draft rule, and the proposal-only clause has all shipped CI criteria unchecked while its remaining HUMAN gate-bound confirmation is a real follow-up. | Approve ticking the three CI criteria through track-work, then answer move follow-up and close or retain here for the named HUMAN item; do not close completed before that decision. (How to respond: reply "agree" to apply remediation, or "decline") |
| Seven title-only ideas (#4 (skills): Skill/loop/routine - holistic repo review; #5 (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights); #7 (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.); #11 (skills): Create skills for documenting, decision records, and their format/template; #14 (skills): SEO/GEO skill; #15 (skills): General product evaluation skill; #16 (skills): Documentation up to date skill) contain no scope or verification, and some overlap only partially with shipped skills. | Ask the maintainer to supply each intended input/output and acceptance criterion; keep these at p3/NEEDS-INFO and do not implement or duplicate-close them from titles alone. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1662 (devflow): Add named run profiles so a skill or operator can select rigor, breadth and strategy together is locally shipped but its template-render criterion is separately tracked by open harmon-init #1864 (devflow): Render the fleet breadth and run profiles in the template policy. | Keep it open with the explicit cross-repository dependency; on the next groom verify the linked template render before ticking the last criterion and proposing closure. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1166 (implement): Extend the lane-brief PII rule to every pushed artifact and gate it per push cites a retired orchestrator path, and #520 (agents): Make agent pushes independent of interactive Git credentials cites retired gauntlet paths/test targets. | Approve narrow body-reference edits to the current orchestrate and review/round-push surfaces while preserving the original privacy and credential requirements. (How to respond: reply "agree" to apply remediation, or "decline") |
| PR candidate indexing includes unrelated numeric/cross-repository references: merged PR #302 fix: update to harmon-init v4.15.1 mentions an earlier cross-repository lifecycle issue and is a candidate for #520 (agents): Make agent pushes independent of interactive Git credentials. | Keep candidates non-authoritative and approve a tooling follow-up that parses explicit same-repository links/closing references separately from bare numbers; require current-file evidence for every closure. (How to respond: reply "agree" to apply remediation, or "decline") |
| #252 (dev-flow): Add custom shell-quality rule forbidding   in grep patterns and #517 (dev-flow): Dev loop: resume yielded gate sessions instead of have titles that lost the operative text or end mid-sentence. | Approve explicit retitles spelling out the grep word-boundary escape and “Resume yielded gate sessions instead of launching duplicates”; apply via groom retitle plan, then triage. (How to respond: reply "agree" to apply remediation, or "decline") |
| #194 (dev-flow): Scripts/shell-quality.sh is an orphan of the template's format-shell.sh + lint-shell.sh split and #383 (ci): Local shellcheck drifts from CI's, so task check passes heads CI then fails retain root-cause claims explicitly corrected by later owner comments. | Respond “reconcile corrected bodies” to authorize scoped track-work body edits: remove the nonexistent snippet blocker and describe ShellCheck mismatch in either direction while retaining historical evidence. (How to respond: reply "agree" to apply remediation, or "decline") |
| #584 (claim): Tolerate a trailing newline in the published claim record retains wholly unchecked criteria after merged PR #1238 fix(claim): normalise trailing newlines on claim record compare delivered normalization and exact-record resume; its model-label criterion remains open and overlaps #580 (claim): Make the record template and helper agree on model-label n/a. | Tick the verified normalization/resume criteria through track-work; either retain the model-label criterion or explicitly transfer it to the named survivor, then close the partial issue only after that transfer is approved and recorded. (How to respond: reply "agree" to apply remediation, or "decline") |
| #437 (claim): Read the rigor:* label and announce the resolved caps — the rung is documented but unread requires a per-stage rigor maximum that current policy supersedes with strongest-profile selection. | Respond “align rigor criteria” to update the stale resolution criterion to current policy and preserve the unimplemented claim-entry announcement, rather than restoring obsolete behavior. (How to respond: reply "agree" to apply remediation, or "decline") |
| #652 (claim-lifecycle): Document the merged-PR event release path still documents no merged-PR event job and a merged-Refs accepted gap, contradicting the upstream behavior described in its full issue history. | Prioritize the existing documentation correction and reconcile wrap fallback wording; retain the HUMAN upstream-contract/pin check until evidence or an approved collector transfer settles it. (How to respond: reply "agree" to apply remediation, or "decline") |
| Several early skill requests contain only titles and no problem, trigger, deliverable or acceptance criteria. | Before implementation, refine #17 (skills): Logging, debugging, observability skill, #18 (deps): Dependency management skill, #19 (security): Security review/audit skill, #20 (skills): Review architecture and refactor until you're satisfied skill, and #310 (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from through track-work; for council, explicitly decide whether the shipped strategy meets the intended request. (How to respond: reply "agree" to apply remediation, or "decline") |
| The watcher enhancement request now mixes substantially shipped observation behavior with stale six-line status and automatic prompt-approval requirements. #816 (skills): ship the orchestrator's agent-status watcher and stall detector as a skill asset has later implementation evidence in merged watcher PRs. | Reconcile the body to distinguish shipped observation behavior from intentionally retained policy constraints; replace the automatic-approval expectation with current authority rules before scheduling residual work. Reply "rescope watcher residual"; do not close solely because a watcher file exists. (How to respond: reply "agree" to apply remediation, or "decline") |
| The original autonomous-invocation premise of #672 (claim): Provide an autonomous-mode path for the claim writes was changed by merged PR #710, while the composed-entrypoint acceptance criteria remain outstanding. | Update the problem statement to the remaining single-entrypoint/refusal-test scope, preserving the script request unless the maintainer explicitly drops it. Reply "rescope composed claim entrypoint". (How to respond: reply "agree" to apply remediation, or "decline") |
| The lane-report-specific lint failure in #1020 (tasks): lint:markdown scans git-excluded files, so a lane report in the worktree fails task verify has been patched by an explicit default glob exclusion, but arbitrary Git-ignore compliance remains unimplemented. | Record the partial fix in the issue and retain the generic ignore-rule regression criteria. Reply "keep generic ignore scope"; do not close from the lane-report exclusion alone. (How to respond: reply "agree" to apply remediation, or "decline") |
| The changed-scope gate proposals overlap between #1021 (tasks): add a quick per-round gate between check and verify for code rounds and #1068 (verify): serialise task verify across parallel lanes and add a changed-scope gate, but the latter also adds a concurrency lock and a different docs/test execution expectation. | Implement one shared changed-input selector after the gate ADR, preserving separate locking work and deciding the docs/test behavior explicitly. Reply "share gate selector, keep lock separate"; do not duplicate-close either whole issue. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1058 (retro): Finish the retro reconstruction follow-ups deferred from PR #991 and #962 is flagged human-only-remaining although its human criteria are the parent completion work itself and live children remain incomplete. | Keep the parent open and treat its completion-candidate flag as advisory only. Reply "retain reconstruction parent"; do not move these human criteria into a collector to force closure. (How to respond: reply "agree" to apply remediation, or "decline") |
| Eighteen assigned issues have long or malformed scoped titles, and #1012 (ci): Consider adding the built-in Claude Code simplify skill to the dev workflow after implement has placeholder text plus an empty acceptance checkbox. | Use the per-row conformance records to prepare an approved retitle/body-edit plan; preserve full titles in body provenance instead of truncating them. For the simplify proposal choose the pilot/decline decision before replacing its empty criterion. (How to respond: reply "agree" to apply remediation, or "decline") |
| #877 (dev-flow runtime): runtime manifest, atomic skills-sync install, offline verification, and /orchestrate preflight — residue after #974 retains its pre-rescope body list although the owner comment assigns relocation/classification work to the merged runtime-relocation change and retains only distribution residuals. | Reconcile the body acceptance list to the 2026-09-19 attributed rescope through track-work, with shipped relocation evidence and explicit remaining manifest/install/preflight obligations. Reply "reconcile runtime residual scope". (How to respond: reply "agree" to apply remediation, or "decline") |
| The title-only strategy naming questions and existing ADR-workflow overlap require maintainer intent rather than another implementation pass. | Answer the five NEEDS-DECISION rows directly; in particular retain council unless market has distinct intended semantics, prefer plan-ask if renaming plan-approved, and use the existing domain-modeling ADR workflow if it satisfies the decision-record idea. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1475 (claim): Retry the post-publication liveness read and let an exact re-run resume repeats the same lagged-publication and assignee-ownership resume scope as #1194 (claim): Re-read post-publication state over a bounded settle window before reporting indeterminate. | Approve closing the later duplicate into the earlier survivor, retaining the later occurrence as reproduction evidence; respond "close duplicate 1475 into 1194". (How to respond: reply "agree" to apply remediation, or "decline") |
| #1134 (dev-flow): render-dev-flow bounds integration adjudication rounds by the Codex-cycle cap although integration_round counts integrator passes remained open after the renderer switched to charged-cycle accounting in merged PR #1511 fix(dev-flow): authorize extra charged integration cycles. | Approve CLOSE-done with renderer:835-863 and immutable commit e6f0a7c4 as evidence; respond "close 1134 done". Treat old downstream pinned failures separately from current-source completion. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1466 (dev-flow): Reject six malformed result and run-record shapes the validator still accepts grew from six to twenty validation cases through two comments; its original title and acceptance list no longer enumerate the whole retained scope. | Use track-work to consolidate all twenty cases into a body inventory, reconcile overlap with #1640 fix(dev-flow-support): tighten plan merge-queue checks across revisions, cap counting and pr binding, then /breakdown only the independently reviewable units; respond "inventory and split schema gaps". Preserve unmilestoned deferred status. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1595 needs-review: orchestrate exclusion for issues it doesn't own, and pull-back order still describes needs-review as a human-review hold although the accepted model now means agent-owed review and #1710 fix(skills): settle the needs-review follow-ups deferred from #1709 carries newer paired-marker follow-ups. | Reconcile the older issue body against the agent-owed model, retain its unowned-delivery planning exclusion, and identify shared pull-back items without closing distinct scope; respond "reconcile needs-review follow-ups". (How to respond: reply "agree" to apply remediation, or "decline") |
| #1715 (HUMAN): Complete manual setup for Orchestrator resilience directs the maintainer to integrate/references/github-app-checks.md, which is absent from the audited main snapshot. | Locate the App-backed gate implementation and wait for its guide to ship, then update the HUMAN collector link and execute only the maintainer-owned setup; respond "repair App setup guide link after implementation". (How to respond: reply "agree" to apply remediation, or "decline") |
| Several retained issue titles fail the issue profile while already using conventional-commit syntax or oversized explanatory titles; per-row conformance records include concrete retitle suggestions. | Review the supplied retitle-plan suggestions with the overall audit and apply only approved rows; respond "approve cluster 11 retitles". Do not retitle the closing candidates unnecessarily. (How to respond: reply "agree" to apply remediation, or "decline") |
| #1681 fix(dev-flow-support): check a pass's producer tier against the registry instead of trusting the envelope documents historical producer tiers that overstated the actual model tier; registry consistency alone will not attest which runtime model executed. | Implement the registry/model cross-check and truthful dispatch guidance, keep historical records immutable with the maintainer-approved disclosures, and state the guarantee as metadata consistency; respond "implement producer consistency check, no historical reruns". (How to respond: reply "agree" to apply remediation, or "decline") |
| Two report presentation details need cautious interpretation: the evidence chart classifies text mentioning a numbered reference as duplicate-link evidence, and automatic conformance can include bot-owned dashboards. | Use the exact verdict table for closure counts (one literal duplicate), and exclude bot dashboards from every edit/close plan. Address renderer fidelity through the existing groom report follow-up; respond retain audit recommendations and fix report presentation separately. (How to respond: reply "agree" to apply remediation, or "decline") |
| Native relationship reads contradicted several inferred regroupings: #1039 (groom): host-qualify gh calls and preflight sub-issue and milestone permissions in apply already belongs to #1015 (skills): Add a groom skill: verify, dispose, regroup, and record decisions across a backlog; #1379 (review): pass prior-round finding records to envelope-mode finders already belongs to #1357 (dev-flow): Leave a v2 run record from every Dev Loop session that /integrate and /retro can use; #517 (dev-flow): Dev loop: resume yielded gate sessions instead of already belongs to #699 (gauntlet): Detach reviewer rounds from harness time caps; #529 (dev-flow): Make background gate runs survive the periodic SIGTERM kills already belongs to #716 (verify): make the verify gate faster and lighter — shellcheck memory, load flakiness, parallel-lane contention; #305 (implementer): Backgrounding the exit gate makes §5 and §7 unsatisfiable — a subagent has no next turn to collect it and #386 (agents): Record that subagent briefs must demand foreground gate runs already belong to #559 (agents): Preserve delegated gate ownership through completion; #1022 (retro): re-verify historical run records with their recorded rounds policy, not the live .devflow.toml caps and #1029 (retro): a run whose only marker was edited after the --as-of cutoff reports not-found instead of indeterminate already belong to #1001 (retro): have the local-record harvester invoke the exit engine's CLI end to end instead of importing its helpers. | Retain the existing parents. Approve only the additive parent links listed in the report; keep cross-cutting design themes as references. Re-read native relationships immediately before any approved link write. (How to respond: reply "agree" to apply remediation, or "decline") |
| Cross-cutting integration themes include issues already committed to other milestones: #820 (integrate): Enforce invariant 10 on historical integrator passes (two-pass known-ID validation) stays in Dev flow v2; #912 (integrate): Require --receipts in integration-stage readiness evaluation stays in Dev flow v2; #949 (integrate): Finder_cycles validation and gate coverage gaps (#804 deferred) stays in Dev flow v2; #1474 (integrate): Hold the readiness gate when the PR body lacks the rendered policy-disclosure section stays in Dev flow v2; #1630 (integrate): Preserve checker-only cycle history when dispatching a later cycle stays in Orchestrator resilience. | Preserve these assignments; the new milestone proposals list only currently unassigned issues. Respond with selected milestone additions, or defer regrouping; no reparenting or milestone reassignment is implied. (How to respond: reply "agree" to apply remediation, or "decline") |
| The initial 619-issue audit used default-branch commit 0ec6bc2e7b381d59500792aebdfd641329bb1f35. A final refresh reconciled the single intervening PR (#1727), removed its now-closed issue, and audited two new issues, leaving complete coverage of 620 open issues at 6f0f32228fe02689e45d87699899e75580f638db on 2026-10-29. | Read the recommendations, approve explicit batches, then refresh affected issues, PR merge states and relationships before planning writes. Keep closures, decisions, title cleanup and structural proposals separately selectable; run triage after approved changes. (How to respond: reply "agree" to apply remediation, or "decline") |

## Conformance

### Body profile

- #1669 — (standardize-repo): Run the GitHub-side reconcile phase in every mode, probing in lanes and writing from the parent — Problem still says parent writes follow a wave merge; authoritative ADR/comment says each individual repository merge. Recommended correction: Use track-work body edit to replace the obsolete wave timing with each repository merge, serialized per owner. (proposed fix: a manual edit)
- #191 — (track-work): A Verify block can be stricter than the criterion it stands for — 3 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #289 — (track-work): The closing-keywords guard ignores the Refs path, where ticks are the only record of partial progress — 6 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #306 — (track-work): A Verify block whose pass condition is 'no output' fails open — 4 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #313 — (track-work): Set-issue-status.sh is host-naive — Projects V2 writes go to the default host — 3 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #503 — (track-work): Normalize backticked branch values in claim records — 5 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #525 — (dev-flow): Refuse truncated live label pages in the metadata fallback vocabulary — Acceptance boxes remain unticked despite the verified shipped behavior. Recommended correction: Record code-backed criterion verification through track-work before an approved completed close. (proposed fix: a track-work tick)
- #553 — (track-work): Support host-qualified metadata checks — Acceptance boxes remain unticked despite the verified shipped behavior. Recommended correction: Record code-backed criterion verification through track-work before an approved completed close. (proposed fix: a track-work tick)
- #626 — (track-work): Lock completed-tick allowlist boundary — 2 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #627 — (track-work): Define post-merge criterion close transition — 3 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #930 — (labels): Single-source the registry_set enum and prefix map — 3 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #981 — (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR — Issue body is empty; scope currently survives only in title and transfer comments. Recommended correction: Expand the body with the batching-only outcome, acceptance criteria and its relationship to the broader groom issue before scheduling implementation. (proposed fix: a manual edit)
- #1231 — (track-work): Require human and umbrella on collector titles — Acceptance boxes remain unticked despite the verified shipped behavior. Recommended correction: Record code-backed criterion verification through track-work before an approved completed close. (proposed fix: a track-work tick)
- #1612 — fix(dev-flow-support): skip needs-review cleanup for replayed events older than the label — 3 unchecked criteria lack [CI]/[HUMAN] tags. Recommended correction: Normalize through track-work; classify each criterion by how it is verified without ticking or deleting work. (proposed fix: a manual edit)
- #1697 — (integrate): Give catch-up fixtures enough time under parallel load — Delivered CI acceptance criteria remain unchecked. Recommended correction: Use track-work to verify and tick the completed criteria before the approved closure. (proposed fix: a track-work tick)
- #1698 — (integrate): Keep readiness carry fixtures parseable on Bash 3.2 — Delivered CI acceptance criteria remain unchecked. Recommended correction: Use track-work to verify and tick the completed criteria before the approved closure. (proposed fix: a track-work tick)
- #474 — (gauntlet): Re-fetch the base before the PR-open ritual — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #488 — (gauntlet): Best-effort existing-PR check at the entry gate, before rounds push — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #489 — (gauntlet): Resolve the per-round push preconditions — workflow triggers and AGENTS.md CI ordering — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #502 — (gauntlet): Neutralize recursive submodule behavior in round pushes — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #510 — (gauntlet): Gauntlet §8: state the converse — a log that stops growing is the hang signal, not patience — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #518 — (gauntlet): Gate gauntlet final checks against the PR merge ref — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #560 — (gauntlet): Document three ways mutation results lie and their guards — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #564 — (gauntlet): Validate guarded-push inputs before running full gates — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #603 — (gauntlet): Dispatch adjudicated findings to owning agents — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #620 — (gauntlet): forbid tree edits and HEAD moves while push-round.sh gates — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #699 — (gauntlet): Detach reviewer rounds from harness time caps — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #707 — (gauntlet): Keep round-gate state outside /tmp — Acceptance/verification instructions name the retired gauntlet surface and must be mapped to the current owner. Recommended correction: Approve a track-work body refresh to current review/implement assets while preserving each remaining invariant. (proposed fix: a manual edit)
- #878 — (dev-flow): Add Greptile to the supported review providers — Issue has no problem statement or acceptance criteria. Recommended correction: Author supplies desired local/cloud surfaces and observable acceptance criteria before implementation. (proposed fix: a manual edit)
- #908 — (dev-flow): Decide whether deferred findings need a dedicated state/memory store (sidecar.md) beyond GitHub issues — Architectural decision issue has only a title and no motivating failure case. Recommended correction: Record the maintainer storage decision and concrete gap, or close if no extra store is needed. (proposed fix: a manual edit)
- #980 — (dev-loop): Have the PR review agent post a mermaid diagram and an illustrative image for each PR — Restored title/provenance contains the request but no observable acceptance criteria. Recommended correction: Add criteria defining publication owner, when imagery is useful, and artifact destination before implementation. (proposed fix: a manual edit)
- #1006 — (orchestrator): plan.json overlap surface should include each lane's accepted fence expansions — Blocked-by prose names merged PR #1005 rather than a current issue dependency. Recommended correction: Remove the stale textual blocker; retain the PR as provenance and record only live issue dependencies. (proposed fix: a manual edit)
- #1023 — (orchestrator): plan.json attributable operator override for policy/dispatcher changes across revisions — Blocked-by prose names merged PR #1016 rather than a current issue dependency. Recommended correction: Remove the stale textual blocker; retain the PR as provenance and record only live issue dependencies. (proposed fix: a manual edit)
- #1395 — (orchestrate): Settle the cloud-lane P2 findings deferred from PR #1385 — Two untagged criteria still describe seven findings although comments expand the scope to fourteen and three are already settled. Recommended correction: Track-work body update: enumerate fourteen findings, mark 4/7/12 settled with merged evidence, and tag the remaining acceptance criteria. (proposed fix: a manual edit)
- #1523 — (orchestrate): ship the tooling a restarted orchestrator needs instead of scratchpad helpers — Parent retains five unchecked mechanism criteria after being split into children, obscuring its human-only restart scope. Recommended correction: Manual edit: replace mechanism criteria with child completion links and retain the human restart criterion. (proposed fix: a manual edit)
- #727 — (devflow): define a schema for run receipts and slot failures — The body still says receipts/slot_failures do not exist in run.schema.json although merged PR #1000 defines both. Recommended correction: Manual body edit: record PR #1000 as partial completion and retain only the unproven exit-input/fixture-validation obligation, coordinating replay producer scope with #977 (dev-flow-stats): make the replay producer emit canonical receipts with authenticated chronology. (proposed fix: a manual edit)
- #1074 — (devflow-policy): derive the deep wall clock from the resolved caps, not a 480-minute constant — The current-violation paragraph says deep still has a 480-minute budget, but main now sets 2880; remaining derivation/measurement and human proof are obscured. Recommended correction: Manual body edit: record the shipped 2880 constant, tick only verified criteria, and clarify whether a derived schema form is still required for the accepted constant alternative. (proposed fix: a manual edit)
- #520 — (agents): Make agent pushes independent of interactive Git credentials — Verify still names retired gauntlet path and test:gauntlet-push task. Recommended correction: Manual body edit to current review/round-push surfaces and actual test targets, preserving the noninteractive credential regression. (proposed fix: a manual edit)
- #855 — (implement): ship a brief template that carries gate bounds, the stop-at-draft rule, and the proposal-only clause — Three shipped CI criteria remain unchecked although merged implementation and current template/test evidence satisfy them. Recommended correction: Use track-work to tick the three CI criteria; keep HUMAN gate-bound confirmation open until its collector/closure decision. (proposed fix: a track-work tick)
- #1166 — (implement): Extend the lane-brief PII rule to every pushed artifact and gate it per push — The first criterion names retired ai/skills/universal/orchestrator/assets/lane-brief.md rather than current orchestrate path. Recommended correction: Manual body edit to ai/skills/universal/orchestrate/assets/lane-brief.md, preserving the output-bound privacy requirement. (proposed fix: a manual edit)
- #4 — (skills): Skill/loop/routine - holistic repo review — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #5 — (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights) — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #7 — (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.) — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #11 — (skills): Create skills for documenting, decision records, and their format/template — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #14 — (skills): SEO/GEO skill — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #15 — (skills): General product evaluation skill — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #16 — (skills): Documentation up to date skill — Empty body: no problem, intended scope, acceptance criteria or verification. Recommended correction: Manual issue edit defining inputs, output and acceptance criteria before implementation. (proposed fix: a manual edit)
- #17 — (skills): Logging, debugging, observability skill — Empty body has no problem statement or acceptance criteria. Recommended correction: Use track-work issue authoring to define the intended trigger, deliverable, and verification. (proposed fix: a manual edit)
- #18 — (deps): Dependency management skill — Empty body has no problem statement or acceptance criteria. Recommended correction: Use track-work issue authoring to define the intended trigger, deliverable, and verification. (proposed fix: a manual edit)
- #19 — (security): Security review/audit skill — Empty body has no problem statement or acceptance criteria. Recommended correction: Use track-work issue authoring to define the intended trigger, deliverable, and verification. (proposed fix: a manual edit)
- #20 — (skills): Review architecture and refactor until you're satisfied skill — Empty body leaves the requested convergence contract undefined. Recommended correction: Define scope and acceptance criteria before implementing or treating existing reviews as equivalent. (proposed fix: a manual edit)
- #194 — (dev-flow): Scripts/shell-quality.sh is an orphan of the template's format-shell.sh + lint-shell.sh split — Body still claims snippet exclusion is a blocker although the owner comment proves snippets contains only a placeholder. Recommended correction: Revise the problem and acceptance criteria to a mechanical successor-script adoption, retaining the historical correction. (proposed fix: a manual edit)
- #221 — (session-flow): Format statuses, reports, outcomes, and tables per session state (orient, retro, close, PRs) — Sketch lacks acceptance criteria and mixes several session reports. Recommended correction: Define the desired reports and obtainable metrics before implementation. (proposed fix: a manual edit)
- #310 — (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from — Empty body does not distinguish a dedicated skill from the shipped council strategy. Recommended correction: Define whether the existing council strategy fulfills the request; add acceptance criteria for any remaining dedicated skill. (proposed fix: a manual edit)
- #383 — (ci): Local shellcheck drifts from CI's, so task check passes heads CI then fails — Body describes local as older although owner correction establishes newer local ShellCheck was laxer. Recommended correction: Update root-cause prose to version mismatch in either direction and retain the owner evidence. (proposed fix: a manual edit)
- #437 — (claim): Read the rigor:* label and announce the resolved caps — the rung is documented but unread — Criteria mandate per-stage maxima while current policy selects the strongest complete rigor profile. Recommended correction: Reconcile criteria to current strongest-profile rule and retain the unfinished claim-entry behavior explicitly. (proposed fix: a manual edit)
- #584 — (claim): Tolerate a trailing newline in the published claim record — The main newline defect shipped but all criteria remain unticked and the record mixes a surviving model-label papercut with the fixed cause. Recommended correction: Tick the verified newline/resume criteria using track-work, then retain or explicitly transfer the model-label criterion to #580 (claim): Make the record template and helper agree on model-label n/a before closing. (proposed fix: a track-work tick)
- #1012 — (ci): Consider adding the built-in Claude Code simplify skill to the dev workflow after implement — Placeholder motivation/solution and an empty acceptance checkbox provide no executable acceptance scope. Recommended correction: Replace placeholders through a track-work body update after the pilot decision; do not mark the blank criterion passed. (proposed fix: a manual edit)
- #1595 — needs-review: orchestrate exclusion for issues it doesn't own, and pull-back order — Problem frames needs-review as waiting for human review, superseded by the adopted agent-owed meaning. Recommended correction: Update scope through track-work to preserve unowned-delivery exclusion and reconcile pull-back work with #1710 fix(skills): settle the needs-review follow-ups deferred from #1709. (proposed fix: a manual edit)
- #1715 — (HUMAN): Complete manual setup for Orchestrator resilience — Human setup criterion points to a github-app-checks.md guide absent from audited main. Recommended correction: When the App-backed gate implementation lands, update this collector to its shipped guide; maintainer completes setup and records a successful check-runs read. (proposed fix: a manual edit)
- #1046 — consider outputting and saving a report as part of the retro skill. Perhaps as a way to make orchestration runs more visible and observible and measurable and improvable. In contrast to issues, milestones, prs, etc orchestration sessions should have some kind of artifact to track and measure and improve. Similar general method to the groom skill report. — empty body (proposed fix: a manual edit)
- #922 — (dev-flow): Decide whether to rename the council strategy to market — empty body (proposed fix: a manual edit)
- #921 — (dev-flow): Rename the plan-approved strategy to say who approves (plan-ask, plan-gated, plan-then-approve) — empty body (proposed fix: a manual edit)
- #908 — (dev-flow): Decide whether deferred findings need a dedicated state/memory store (sidecar.md) beyond GitHub issues — empty body (proposed fix: a manual edit)
- #882 — (dev-flow): Add Claude Code artifacts (HTML reports) to the dev flow — empty body (proposed fix: a manual edit)
- #878 — (dev-flow): Add Greptile to the supported review providers — empty body (proposed fix: a manual edit)
- #854 — (dev-flow): Consider a prompt-registry JSON that declares and validates per-harness, per-role prompts — empty body (proposed fix: a manual edit)
- #802 — (skills): Add a /learn skill that turns a correction into a dev-loop change (memory, artifact, or .devflow.toml setting) — empty body (proposed fix: a manual edit)
- #712 — (session-flow): Record a timestamp in kickoff, claim, and implement so wall-clock time per stage can be computed — empty body (proposed fix: a manual edit)
- #605 — (skills): Decide whether third-party skills (e.g. Matt Pocock's) get their own skill category — empty body (proposed fix: a manual edit)
- #981 — (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR — empty body (proposed fix: a manual edit)
- #310 — (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from — empty body (proposed fix: a manual edit)
- #979 — (skills): Create skill and prompt for nightly docs sync routine — empty body (proposed fix: a manual edit)
- #20 — (skills): Review architecture and refactor until you're satisfied skill — empty body (proposed fix: a manual edit)
- #19 — (security): Security review/audit skill — empty body (proposed fix: a manual edit)
- #18 — (deps): Dependency management skill — empty body (proposed fix: a manual edit)
- #17 — (skills): Logging, debugging, observability skill — empty body (proposed fix: a manual edit)
- #16 — (skills): Documentation up to date skill — empty body (proposed fix: a manual edit)
- #15 — (skills): General product evaluation skill — empty body (proposed fix: a manual edit)
- #14 — (skills): SEO/GEO skill — empty body (proposed fix: a manual edit)
- #978 — (ci): Create a skill to create decision records — empty body (proposed fix: a manual edit)
- #11 — (skills): Create skills for documenting, decision records, and their format/template — empty body (proposed fix: a manual edit)
- #7 — (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.) — empty body (proposed fix: a manual edit)
- #5 — (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights) — empty body (proposed fix: a manual edit)
- #4 — (skills): Skill/loop/routine - holistic repo review — empty body (proposed fix: a manual edit)

### Labels

- #1419 — (orchestrator): give Codex lanes a writable pnpm store and stage lane changes from git status — Pre-audit triage retained missing layer; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #1350 — (breakdown): Assert fallback rating families never carry Priority (AI) or suggest labels — axis-conflict:area (proposed fix: a manual edit)
- #1350 — (breakdown): Assert fallback rating families never carry Priority (AI) or suggest labels — Pre-audit triage retained missing area; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #1159 — (integrate): make integrator passes immutable and their Codex verdicts self-authenticating — Pre-audit triage retained missing area, domain, layer, impact, risk, complexity while actively claimed; do not relabel during the claim (proposed fix: a manual edit)
- #882 — (dev-flow): Add Claude Code artifacts (HTML reports) to the dev flow — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #878 — (dev-flow): Add Greptile to the supported review providers — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #854 — (dev-flow): Consider a prompt-registry JSON that declares and validates per-harness, per-role prompts — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #717 — (implement): Rerun the one failing gate task alone twice instead of the full verify — axis-conflict:area (proposed fix: a manual edit)
- #717 — (implement): Rerun the one failing gate task alone twice instead of the full verify — Pre-audit triage retained missing area; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #981 — (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #310 — (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #277 — (dev-flow): Open-source readiness audit (public-repo hardening) — rollup — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #979 — (skills): Create skill and prompt for nightly docs sync routine — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #20 — (skills): Review architecture and refactor until you're satisfied skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #19 — (security): Security review/audit skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #18 — (deps): Dependency management skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #17 — (skills): Logging, debugging, observability skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #16 — (skills): Documentation up to date skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #15 — (skills): General product evaluation skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #14 — (skills): SEO/GEO skill — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #978 — (ci): Create a skill to create decision records — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #11 — (skills): Create skills for documenting, decision records, and their format/template — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #7 — (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.) — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #5 — (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights) — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #4 — (skills): Skill/loop/routine - holistic repo review — Pre-audit triage retained missing impact, risk, complexity; clarify scope or conflicting classification before rerunning triage (proposed fix: a manual edit)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — Only needs-triage is present; work type, area/domain/layer and classification axes are not yet assigned. Recommended correction: Run the existing triage classification path and apply only the approved label plan; keep execution-policy labels untouched. (proposed fix: a triage apply)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — missing work type (proposed fix: a triage apply)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — partially classified (proposed fix: a triage apply)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — axis-missing:area (proposed fix: a triage apply)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — axis-missing:domain (proposed fix: a triage apply)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — axis-missing:layer (proposed fix: a triage apply)
- #1419 — (orchestrator): give Codex lanes a writable pnpm store and stage lane changes from git status — partially classified (proposed fix: a triage apply)
- #1419 — (orchestrator): give Codex lanes a writable pnpm store and stage lane changes from git status — axis-missing:layer (proposed fix: a triage apply)
- #1350 — (breakdown): Assert fallback rating families never carry Priority (AI) or suggest labels — partially classified (proposed fix: a triage apply)
- #1159 — (integrate): make integrator passes immutable and their Codex verdicts self-authenticating — partially classified (proposed fix: a triage apply)
- #1159 — (integrate): make integrator passes immutable and their Codex verdicts self-authenticating — axis-missing:area (proposed fix: a triage apply)
- #1159 — (integrate): make integrator passes immutable and their Codex verdicts self-authenticating — axis-missing:domain (proposed fix: a triage apply)
- #1159 — (integrate): make integrator passes immutable and their Codex verdicts self-authenticating — axis-missing:layer (proposed fix: a triage apply)
- #882 — (dev-flow): Add Claude Code artifacts (HTML reports) to the dev flow — needs-triage label is removable (proposed fix: a triage apply)
- #878 — (dev-flow): Add Greptile to the supported review providers — needs-triage label is removable (proposed fix: a triage apply)
- #854 — (dev-flow): Consider a prompt-registry JSON that declares and validates per-harness, per-role prompts — needs-triage label is removable (proposed fix: a triage apply)
- #717 — (implement): Rerun the one failing gate task alone twice instead of the full verify — partially classified (proposed fix: a triage apply)
- #981 — (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR — needs-triage label is removable (proposed fix: a triage apply)
- #561 — Dependency Dashboard — needs-triage label is removable (proposed fix: a triage apply)
- #536 — (triage): Track backlog findings — missing work type (proposed fix: a triage apply)
- #536 — (triage): Track backlog findings — partially classified (proposed fix: a triage apply)
- #536 — (triage): Track backlog findings — axis-missing:area (proposed fix: a triage apply)
- #536 — (triage): Track backlog findings — axis-missing:domain (proposed fix: a triage apply)
- #536 — (triage): Track backlog findings — axis-missing:layer (proposed fix: a triage apply)
- #310 — (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from — needs-triage label is removable (proposed fix: a triage apply)
- #277 — (dev-flow): Open-source readiness audit (public-repo hardening) — rollup — needs-triage label is removable (proposed fix: a triage apply)
- #127 — (deps): Dependency Dashboard — needs-triage label is removable (proposed fix: a triage apply)
- #979 — (skills): Create skill and prompt for nightly docs sync routine — needs-triage label is removable (proposed fix: a triage apply)
- #20 — (skills): Review architecture and refactor until you're satisfied skill — needs-triage label is removable (proposed fix: a triage apply)
- #19 — (security): Security review/audit skill — needs-triage label is removable (proposed fix: a triage apply)
- #18 — (deps): Dependency management skill — needs-triage label is removable (proposed fix: a triage apply)
- #17 — (skills): Logging, debugging, observability skill — needs-triage label is removable (proposed fix: a triage apply)
- #16 — (skills): Documentation up to date skill — needs-triage label is removable (proposed fix: a triage apply)
- #15 — (skills): General product evaluation skill — needs-triage label is removable (proposed fix: a triage apply)
- #14 — (skills): SEO/GEO skill — needs-triage label is removable (proposed fix: a triage apply)
- #978 — (ci): Create a skill to create decision records — needs-triage label is removable (proposed fix: a triage apply)
- #11 — (skills): Create skills for documenting, decision records, and their format/template — needs-triage label is removable (proposed fix: a triage apply)
- #7 — (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.) — needs-triage label is removable (proposed fix: a triage apply)
- #5 — (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights) — needs-triage label is removable (proposed fix: a triage apply)
- #4 — (skills): Skill/loop/routine - holistic repo review — needs-triage label is removable (proposed fix: a triage apply)

### Title

- #1685 — fix(standardize-repo): finish the split-jobs vocabulary and make gate reachability leaf-based — PR-style conventional-commit prefix violates the issue title contract. Recommended correction: Retitle through groom plan to (standardize-repo): Finish the split-jobs vocabulary and make gate reachability leaf-based (proposed fix: a retitle plan row)
- #1707 — fix(standardize-repo): finish the rigor-label retirement and domain-extension steps — PR-style conventional-commit prefix violates the issue title contract. Recommended correction: Retitle through groom plan to (standardize-repo): Finish the rigor-label retirement and domain-extension steps (proposed fix: a retitle plan row)
- #289 — (track-work): The closing-keywords guard ignores the Refs path, where ticks are the only record of partial progress — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #981 — (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #1033 — (groom): harden outcomes handling — dataset identity, missing-file opt-in, lost-record exit code, render tests — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #1034 — (groom): fix report and dry-run fidelity — bot-owned rows, label PLAN detail, refusal and pty test coverage — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #1047 — (track-work): Host-qualify every GitHub write path so a wrong host or missing scope is refused before writing — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #1048 — (track-work): Make Verify blocks fail closed — one authoring rule for no-output and planning-profile checks — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #1085 — (skills): Add an opt-in live test that runs the wrappers' real permission grants through the installed Claude CLI — Title exceeds the shared soft length limit. Recommended correction: Offer a meaning-preserving retitle plan row; move removed wording into the body and run the previous-title predicate. (proposed fix: a retitle plan row)
- #1609 — fix(track-work): refuse wrong-case ratings before filing and tighten file-review-finding follow-ups — Title uses a conventional-commit prefix instead of the canonical (scope): issue form. Recommended correction: Add a supervised retitle plan row preserving meaning: (track-work): Refuse wrong-case ratings before filing and tighten follow-ups (proposed fix: a retitle plan row)
- #1612 — fix(dev-flow-support): skip needs-review cleanup for replayed events older than the label — Title uses a conventional-commit prefix instead of the canonical (scope): issue form. Recommended correction: Add a supervised retitle plan row preserving meaning: (dev-flow-support): Preserve needs-review markers newer than replayed events (proposed fix: a retitle plan row)
- #419 — (shepherd): Shepherd check: carry acceptance ignores .state and — Title ends with an incomplete conjunction and omits the PR state/head subject. Recommended correction: Retitle plan: (integrate): Validate PR state and head before accepting carry (proposed fix: a retitle plan row)
- #1115 — fix(integrate): give a quota-exhausted Codex head a safe recovery route after exit 15 — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Recover a quota-exhausted review cycle safely (proposed fix: a retitle plan row)
- #1117 — feat(integrate): accept the Codex summary Completed row as terminal-clean under the head-binding invariants — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Bind completed summary verdicts to the current head (proposed fix: a retitle plan row)
- #1140 — (integrate): readiness gate reads only the first 100 closingIssuesReferences, so a body claiming more issues fails closing-linkage permanently — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Paginate closing-issue linkage before gating (proposed fix: a retitle plan row)
- #1142 — (integrate): the closing-target issue lookup classifies any object without pull_request as an issue without checking its identity — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Validate closing-target issue identity (proposed fix: a retitle plan row)
- #1152 — fix(integrate): apply the charged/exempt pair and sum checks to finder_cycles[] — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Validate every finder cycle spend pair (proposed fix: a retitle plan row)
- #1153 — fix(integrate): reap a run-spend sidecar orphaned by the quota-recovery path — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Reap orphaned review-spend sidecars (proposed fix: a retitle plan row)
- #1175 — integrate: three fail-closed carry edge cases from #1163's final review cycle — Title does not follow the concise (&lt;scope&gt;): &lt;imperative outcome&gt; contract. Recommended correction: Retitle plan: (integrate): Recover safely from carried-review edge cases (proposed fix: a retitle plan row)
- #1366 — (review): local Codex review passes run with approval on-request, so reviewed content can request unsandboxed commands — Title still states the on-request exposure after the issue comment establishes the review subcommand uses approval never. Recommended correction: Retitle to verify the effective local Codex approval posture with a reviewed-diff escalation regression; preserve the historical plain-exec evidence in the body. (proposed fix: a retitle plan row)
- #252 — (dev-flow): Add custom shell-quality rule forbidding   in grep patterns — Title loses the backslash-b construct and reads as an empty gap. Recommended correction: Retitle to describe forbidden grep word-boundary escapes explicitly without escape interpretation. (proposed fix: a retitle plan row)
- #517 — (dev-flow): Dev loop: resume yielded gate sessions instead of — Title ends after “instead of” and omits the alternative action. Recommended correction: Retitle to “(dev-flow): Resume yielded gate sessions instead of launching duplicates”. (proposed fix: a retitle plan row)
- #712 — (session-flow): Record a timestamp in kickoff, claim, and implement so wall-clock time per stage can be computed — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #802 — (skills): Add a /learn skill that turns a correction into a dev-loop change (memory, artifact, or .devflow.toml setting) — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #854 — (dev-flow): Consider a prompt-registry JSON that declares and validates per-harness, per-role prompts — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #877 — (dev-flow runtime): runtime manifest, atomic skills-sync install, offline verification, and /orchestrate preflight — residue after #974 — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #921 — (dev-flow): Rename the plan-approved strategy to say who approves (plan-ask, plan-gated, plan-then-approve) — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #990 — (retro): a PR-only evidence marker with no local record is invisible to the targeted --run invocation — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #994 — (retro): Evidence-only and integrity output should carry discovery anomalies, the as-of cutoff, and verification gaps — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1022 — (retro): re-verify historical run records with their recorded rounds policy, not the live .devflow.toml caps — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1029 — (retro): a run whose only marker was edited after the --as-of cutoff reports not-found instead of indeterminate — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1046 — consider outputting and saving a report as part of the retro skill. Perhaps as a way to make orchestration runs more visible and observible and measurable and improvable. In contrast to issues, milestones, prs, etc orchestration sessions should have some kind of artifact to track and measure and improve. Similar general method to the groom skill report. — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1097 — (docs): the Codex guide says a cap of 0 never waives the current-head clean signal, contradicting AGENTS.md — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1099 — (dev-flow): mechanical guard that fails task verify when a vendored skill or agent invokes a repository-root scripts/ path — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1104 — docs(orchestrate): document OBSERVATION-DEGRADED and retire the restart-loop guidance in SKILL.md — Current title does not conform to the repository scoped-title profile. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1105 — fix(orchestrate): poll an armed post-promotion window even while PR discovery is backing off — Current title does not conform to the repository scoped-title profile. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1106 — test(orchestrate): cover lane-watch's round-2 fixes, skip gates, and the re-promotion 10/11 branch — Current title does not conform to the repository scoped-title profile. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1107 — fix(orchestrate): harden lane-watch against an invalid retry timestamp and same-second id-less malformed rows — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1113 — fix(dev-flow-support): cover every closure reader layout in the fixtures and refuse symlinked candidates — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1114 — test(skills): make the AC-5 vendored sweep hermetic and decide how vendored suites get their fixture corpus — Current title does not conform to the repository scoped-title profile and exceeds its length guidance. Recommended correction: Apply an approved retitle-plan row preserving full scope; move detail into the body instead of truncating the title. (proposed fix: a retitle plan row)
- #1136 — fix(test): GNU-only date -d breaks test-integrate-codex.sh on macOS — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (tests): Compute integrate timestamps portably and guard GNU-only commands (proposed fix: a retitle plan row)
- #1154 — fix(dev-flow): carry the exempt ceiling through the orchestrated cap contracts — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Carry integration-exempt caps through orchestration contracts (proposed fix: a retitle plan row)
- #1155 — test(integrate): test-integrate-codex.sh exited 2 once under load — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (tests): Diagnose integrate-codex exit-2 failures under load (proposed fix: a retitle plan row)
- #1158 — (dev-flow): one policy.json contract for the run record, read identically by the readiness gate renderer and the retro harvester — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): one policy.json contract for the run record, read identically by the readiness gate renderer and the retro harvester (proposed fix: a retitle plan row)
- #1171 — schema: the codex-cloud mirror in finder_cycles[] may contradict codex_cycle — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (schemas): Resolve the redundant Codex-cycle mirror contract (proposed fix: a retitle plan row)
- #1369 — feat(dev-flow): persist per-round exit verdicts so split adjudications can be bound to their candidate — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Persist identity-bound exit verdicts for every round (proposed fix: a retitle plan row)
- #1375 — fix(dev-flow-support): harden split chronology and issue-pattern anchoring after #1373 — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Enforce split chronology and issue-reference anchoring (proposed fix: a retitle plan row)
- #1404 — feat(dev-flow): evaluate remediation pushes in one chronological pass to make the fixing ceiling airtight — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Evaluate remediation pushes in recorded event order (proposed fix: a retitle plan row)
- #1430 — fix(integrate): make the with-push path resilient to finder refusal and CI settling mid-review — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (integrate): Continue other finders after refusal and refresh CI (proposed fix: a retitle plan row)
- #1443 — fix(integrate): harden the CI-failed exempt charge (superseded cycles, fork and external CI, run selection, gate snapshot) — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (integrate): Harden CI-failed review-cycle charge accounting (proposed fix: a retitle plan row)
- #1565 — fix(review): make round-push's docs_only_paths glob segment-aware like the CI classifier — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (review): Align docs-only glob matching with the CI classifier (proposed fix: a retitle plan row)
- #1595 — needs-review: orchestrate exclusion for issues it doesn't own, and pull-back order — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-loop): Exclude unowned review deliveries and preserve pull-back claims (proposed fix: a retitle plan row)
- #1624 — fix(dev-flow-support): bind recorded policy projections to their run in lane-init and solo-init — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Bind initialized policy projections to their run (proposed fix: a retitle plan row)
- #1628 — feat(orchestrate): state the one-head merge queue, ready-claim re-check and flake policy — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (orchestrate): State the one-head merge queue and flake policy (proposed fix: a retitle plan row)
- #1640 — fix(dev-flow-support): tighten plan merge-queue checks across revisions, cap counting and pr binding — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Enforce merge-queue revision and PR-binding invariants (proposed fix: a retitle plan row)
- #1655 — docs(orchestrate): finish the sentinel vocabulary in test labels and lane-brief prose — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (orchestrate): Finish sentinel vocabulary in tests and lane briefs (proposed fix: a retitle plan row)
- #1681 — fix(dev-flow-support): check a pass's producer tier against the registry instead of trusting the envelope — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (dev-flow): Cross-check pass producer tiers against the registry (proposed fix: a retitle plan row)
- #1710 — fix(skills): settle the needs-review follow-ups deferred from #1709 — Issue title fails the repository title profile. Recommended correction: Use a reviewed retitle-plan row: (skills): Settle deferred needs-review lifecycle follow-ups (proposed fix: a retitle plan row)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — The new issue uses a free-form lane-watch prefix rather than the repository scoped-title profile. Recommended correction: Use an approved retitle-plan row such as (orchestrate): Fix watcher retry budgets and exit classification; retain both findings in the body. (proposed fix: a retitle plan row)
- #1731 — lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad — malformed issue title (proposed fix: a retitle plan row)
- #1719 — (orchestrate): test-provision-lane compares an unresolved /var temp path against the resolved /private/var one on macOS — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1718 — (retro): test-retro-run-report's ENOENT race cases fail on macOS, where descriptor containment is refused — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1717 — (skills): Run git reads, scripts and interpreters as their own Bash commands, not inside bash -c wrappers — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1710 — fix(skills): settle the needs-review follow-ups deferred from #1709 — malformed issue title (proposed fix: a retitle plan row)
- #1707 — fix(standardize-repo): finish the rigor-label retirement and domain-extension steps — malformed issue title (proposed fix: a retitle plan row)
- #1692 — (orchestrate, implement): Clarify the one-write rule for lane-init, the path shorthand, and the solo recipe — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1685 — fix(standardize-repo): finish the split-jobs vocabulary and make gate reachability leaf-based — malformed issue title (proposed fix: a retitle plan row)
- #1682 — (orchestrate, integrate): Run pollers as bounded background passes, and fail loudly when gh or herdr is unreachable — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1681 — fix(dev-flow-support): check a pass's producer tier against the registry instead of trusting the envelope — malformed issue title (proposed fix: a retitle plan row)
- #1681 — fix(dev-flow-support): check a pass's producer tier against the registry instead of trusting the envelope — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1670 — (standardize-repo): Report each repo's devcontainer definition, CI image and staleness, and queue rebuilds — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1669 — (standardize-repo): Run the GitHub-side reconcile phase in every mode, probing in lanes and writing from the parent — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1667 — (standardize-repo): Keep a per-run fleet report on the epic and a per-repo report on each tracking issue — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1666 — (standardize-repo): Default the slash command to a fleet run built from the inventory, with waves by owner — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1665 — (standardize-repo): Ask a fixed start-of-run question set and record the answers in the fleet decisions file — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1662 — (devflow): Add named run profiles so a skill or operator can select rigor, breadth and strategy together — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1659 — (review-scope): Review only the application of the template, and keep skills pins at the release minimum — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1655 — docs(orchestrate): finish the sentinel vocabulary in test labels and lane-brief prose — malformed issue title (proposed fix: a retitle plan row)
- #1648 — fix(integrate): attribute App-bound required commit statuses in the readiness gate — malformed issue title (proposed fix: a retitle plan row)
- #1640 — fix(dev-flow-support): tighten plan merge-queue checks across revisions, cap counting and pr binding — malformed issue title (proposed fix: a retitle plan row)
- #1628 — feat(orchestrate): state the one-head merge queue, ready-claim re-check and flake policy — malformed issue title (proposed fix: a retitle plan row)
- #1627 — feat(orchestrate): watch promoted and parked PRs until merge instead of a fixed window — malformed issue title (proposed fix: a retitle plan row)
- #1624 — fix(dev-flow-support): bind recorded policy projections to their run in lane-init and solo-init — malformed issue title (proposed fix: a retitle plan row)
- #1612 — fix(dev-flow-support): skip needs-review cleanup for replayed events older than the label — malformed issue title (proposed fix: a retitle plan row)
- #1609 — fix(track-work): refuse wrong-case ratings before filing and tighten file-review-finding follow-ups — malformed issue title (proposed fix: a retitle plan row)
- #1603 — (orchestrate): Keep one merge-ready queue head, park the rest as drafts, and watch promoted PRs until merge — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1595 — needs-review: orchestrate exclusion for issues it doesn't own, and pull-back order — malformed issue title (proposed fix: a retitle plan row)
- #1584 — feat(integrate): request advisory Greptile reviews while draft and never gate on them — malformed issue title (proposed fix: a retitle plan row)
- #1579 — (orchestrate): Record a lane's stage transitions before its finder runs, so a pass is never dated before its stage — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1570 — (retro): report unmeasured remediation and rejected-pass gaps honestly in older and edge-case records — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1568 — (dev-flow-support): refuse pre-token readers and re-check slate-lock ownership inside the write mutex — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1565 — fix(review): make round-push's docs_only_paths glob segment-aware like the CI classifier — malformed issue title (proposed fix: a retitle plan row)
- #1508 — (integrate): let the readiness gate reach a verdict on Actions-only evidence when the token cannot read check runs — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1502 — (integrate): Let a token without checks-rollup access reach a Codex review with a representable result — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1493 — (review): Resolve the repo root in test-post-evidence.sh without a fixed parent depth, so vendored copies work — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1491 — (integrate): Accept a terminal run record for first-adoption runs that intentionally publish no issue evidence — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1460 — (dev-flow-exit): Let a declined false positive in a tell cycle not block a delete or restructure push — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1445 — (dev-flow-support): let a solo run invalidate a stale unadjudicated pass instead of wedging the round — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1443 — fix(integrate): harden the CI-failed exempt charge (superseded cycles, fork and external CI, run selection, gate snapshot) — malformed issue title (proposed fix: a retitle plan row)
- #1443 — fix(integrate): harden the CI-failed exempt charge (superseded cycles, fork and external CI, run selection, gate snapshot) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1435 — (orchestrate): Have the orchestrator attest the lane's model and effort in the brief for harnesses with no self-readable status line — malformed issue title (proposed fix: a retitle plan row)
- #1435 — (orchestrate): Have the orchestrator attest the lane's model and effort in the brief for harnesses with no self-readable status line — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1433 — (integrate): Refuse a registered evidence comment whose first line is not the canonical dev-flow-v2-evidence marker — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1430 — fix(integrate): make the with-push path resilient to finder refusal and CI settling mid-review — malformed issue title (proposed fix: a retitle plan row)
- #1417 — (orchestrator): claim for lanes only through claim-transaction.sh and validate the record at claim time — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1412 — (review): harden post-evidence.sh publication against hung calls, a full comment scan and listing lag — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1404 — feat(dev-flow): evaluate remediation pushes in one chronological pass to make the fixing ceiling airtight — malformed issue title (proposed fix: a retitle plan row)
- #1404 — feat(dev-flow): evaluate remediation pushes in one chronological pass to make the fixing ceiling airtight — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1398 — (dev-flow-support): Refuse replace refs and malformed two-argument flags on the merge-base governance path — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1382 — (retro): render dev-flow-stats adjudication overrides in the retro report and drop the #753-pending notes — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1380 — fix(integrate): harden update-branch.sh against mid-call state, base and verifier changes — malformed issue title (proposed fix: a retitle plan row)
- #1378 — (agent-registry): reconcile copilot-cli harness roles with its registered challenge/review finders, and enforce one authority — malformed issue title (proposed fix: a retitle plan row)
- #1378 — (agent-registry): reconcile copilot-cli harness roles with its registered challenge/review finders, and enforce one authority — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1375 — fix(dev-flow-support): harden split chronology and issue-pattern anchoring after #1373 — malformed issue title (proposed fix: a retitle plan row)
- #1369 — feat(dev-flow): persist per-round exit verdicts so split adjudications can be bound to their candidate — malformed issue title (proposed fix: a retitle plan row)
- #1369 — feat(dev-flow): persist per-round exit verdicts so split adjudications can be bound to their candidate — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1366 — (review): local Codex review passes run with approval on-request, so reviewed content can request unsandboxed commands — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1297 — (orchestrate): Signal lane state through a structured status file instead of a matched report heading — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1296 — (orchestrate): Keep orchestrator state in the Git common directory and ship tested run-record and plan writers — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1293 — (integrate): Honour a per-reviewer cadence from .devflow.toml and support Gemini and Claude as PR-side finders — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1292 — (dev-flow): Apply per-stage empty-round floors from .devflow.toml in the reader, exit engine and readiness gate — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1290 — (orchestrate): Let Antigravity lanes run their gates without approvals, confirm prompt delivery, and stay in their own lane — malformed issue title (proposed fix: a retitle plan row)
- #1290 — (orchestrate): Let Antigravity lanes run their gates without approvals, confirm prompt delivery, and stay in their own lane — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1288 — (orchestrate): Park supervision while only a human can move the run, and let lane-watch exit on the first terminal event — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1280 — (validate): Fail a role result whose producer tier departs from the resolved tier without a disclosure — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1278 — (orchestrate): Let a lane continue past an empty confidence round without waiting for the orchestrator — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1277 — (integrator): Report reviewer summaries, repeated declined comments and unsolicited finder comments without recording them as findings — malformed issue title (proposed fix: a retitle plan row)
- #1277 — (integrator): Report reviewer summaries, repeated declined comments and unsolicited finder comments without recording them as findings — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1175 — integrate: three fail-closed carry edge cases from #1163's final review cycle — malformed issue title (proposed fix: a retitle plan row)
- #1171 — schema: the codex-cloud mirror in finder_cycles[] may contradict codex_cycle — malformed issue title (proposed fix: a retitle plan row)
- #1169 — (orchestrator): Verify a Codex prompt started a turn on the expected model before treating it as delivered — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1165 — (orchestrator): Require an invariant-plus-self-check directive when consecutive review cycles repeat a finding class — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1158 — (dev-flow): one policy.json contract for the run record, read identically by the readiness gate renderer and the retro harvester — malformed issue title (proposed fix: a retitle plan row)
- #1158 — (dev-flow): one policy.json contract for the run record, read identically by the readiness gate renderer and the retro harvester — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1156 — (orchestrate): digest evidence comments over the body as posted, and record the digest the harvester recomputes — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1155 — test(integrate): test-integrate-codex.sh exited 2 once under load — malformed issue title (proposed fix: a retitle plan row)
- #1154 — fix(dev-flow): carry the exempt ceiling through the orchestrated cap contracts — malformed issue title (proposed fix: a retitle plan row)
- #1153 — fix(integrate): reap a run-spend sidecar orphaned by the quota-recovery path — malformed issue title (proposed fix: a retitle plan row)
- #1152 — fix(integrate): apply the charged/exempt pair and sum checks to finder_cycles[] — malformed issue title (proposed fix: a retitle plan row)
- #1150 — (agents): the delegation contract's scratch-directory rule binds the bounded integrator, whose brief has no such field — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1149 — (agents): the delegation contract's branch comparison needs a captured branch that read-only role dispatches do not supply — malformed issue title (proposed fix: a retitle plan row)
- #1149 — (agents): the delegation contract's branch comparison needs a captured branch that read-only role dispatches do not supply — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1148 — (implement): hostile-title fixture does not exercise a backtick run as long as the code-span delimiter — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1147 — (implement): the dispatch procedure in implement/SKILL.md still performs the post-render placeholder scan the template replaced — malformed issue title (proposed fix: a retitle plan row)
- #1147 — (implement): the dispatch procedure in implement/SKILL.md still performs the post-render placeholder scan the template replaced — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1145 — (orchestrate): lane-brief.md's own env-var rule is still categorical and forbids the release-title preflight inputs — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1142 — (integrate): the closing-target issue lookup classifies any object without pull_request as an issue without checking its identity — malformed issue title (proposed fix: a retitle plan row)
- #1142 — (integrate): the closing-target issue lookup classifies any object without pull_request as an issue without checking its identity — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1140 — (integrate): readiness gate reads only the first 100 closingIssuesReferences, so a body claiming more issues fails closing-linkage permanently — malformed issue title (proposed fix: a retitle plan row)
- #1140 — (integrate): readiness gate reads only the first 100 closingIssuesReferences, so a body claiming more issues fails closing-linkage permanently — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1136 — fix(test): GNU-only date -d breaks test-integrate-codex.sh on macOS — malformed issue title (proposed fix: a retitle plan row)
- #1134 — (dev-flow): render-dev-flow bounds integration adjudication rounds by the Codex-cycle cap although integration_round counts integrator passes — malformed issue title (proposed fix: a retitle plan row)
- #1134 — (dev-flow): render-dev-flow bounds integration adjudication rounds by the Codex-cycle cap although integration_round counts integrator passes — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1133 — (agents): integrator §7 assembly template hardcodes status completed, defeating the consecutive-16 blocked report — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1130 — (integrate): a quota reply landing between attempt 1's snapshot and attempt 2's reservation is never seen — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1129 — (integrate): usage-limit substring test classifies a finding that quotes the quota message as quota exhaustion — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1128 — (schemas): validator verdict aggregation keeps a non-exact demand when an equal-rank exact one follows it — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1127 — (integrate): settled unbound badged comments never certify a head, so the cycle ends by escalation instead of clean — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1126 — (integrate): an unbadged concern written as a bullet inside a self-fix summary still classifies informational — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1117 — feat(integrate): accept the Codex summary Completed row as terminal-clean under the head-binding invariants — malformed issue title (proposed fix: a retitle plan row)
- #1117 — feat(integrate): accept the Codex summary Completed row as terminal-clean under the head-binding invariants — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1115 — fix(integrate): give a quota-exhausted Codex head a safe recovery route after exit 15 — malformed issue title (proposed fix: a retitle plan row)
- #1114 — test(skills): make the AC-5 vendored sweep hermetic and decide how vendored suites get their fixture corpus — malformed issue title (proposed fix: a retitle plan row)
- #1114 — test(skills): make the AC-5 vendored sweep hermetic and decide how vendored suites get their fixture corpus — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1113 — fix(dev-flow-support): cover every closure reader layout in the fixtures and refuse symlinked candidates — malformed issue title (proposed fix: a retitle plan row)
- #1113 — fix(dev-flow-support): cover every closure reader layout in the fixtures and refuse symlinked candidates — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1112 — fix(review): derive round-push.sh's policy-reader path from the configured skills destination — malformed issue title (proposed fix: a retitle plan row)
- #1107 — fix(orchestrate): harden lane-watch against an invalid retry timestamp and same-second id-less malformed rows — malformed issue title (proposed fix: a retitle plan row)
- #1107 — fix(orchestrate): harden lane-watch against an invalid retry timestamp and same-second id-less malformed rows — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1106 — test(orchestrate): cover lane-watch's round-2 fixes, skip gates, and the re-promotion 10/11 branch — malformed issue title (proposed fix: a retitle plan row)
- #1105 — fix(orchestrate): poll an armed post-promotion window even while PR discovery is backing off — malformed issue title (proposed fix: a retitle plan row)
- #1104 — docs(orchestrate): document OBSERVATION-DEGRADED and retire the restart-loop guidance in SKILL.md — malformed issue title (proposed fix: a retitle plan row)
- #1099 — (dev-flow): mechanical guard that fails task verify when a vendored skill or agent invokes a repository-root scripts/ path — malformed issue title (proposed fix: a retitle plan row)
- #1099 — (dev-flow): mechanical guard that fails task verify when a vendored skill or agent invokes a repository-root scripts/ path — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1097 — (docs): the Codex guide says a cap of 0 never waives the current-head clean signal, contradicting AGENTS.md — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1085 — (skills): Add an opt-in live test that runs the wrappers' real permission grants through the installed Claude CLI — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1082 — (scripts): Consolidate the three BSD/GNU sed in-place idioms into one write-through helper under scripts/lib — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1057 — (schemas): Apply the PR #1016 plan-validator hardening to the run, adjudication, and envelope schemas — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1056 — (review): Land the current-head review follow-ups deferred from PR #768 as one trust-boundary body of work — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1055 — (schemas): Protect the run record's chain fields — original arrays plus promotion — as one schema change — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1052 — (docs): Decide one routine for keeping documentation and notes fresh instead of three overlapping ideas — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1048 — (track-work): Make Verify blocks fail closed — one authoring rule for no-output and planning-profile checks — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1047 — (track-work): Host-qualify every GitHub write path so a wrong host or missing scope is refused before writing — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1046 — consider outputting and saving a report as part of the retro skill. Perhaps as a way to make orchestration runs more visible and observible and measurable and improvable. In contrast to issues, milestones, prs, etc orchestration sessions should have some kind of artifact to track and measure and improve. Similar general method to the groom skill report. — malformed issue title (proposed fix: a retitle plan row)
- #1046 — consider outputting and saving a report as part of the retro skill. Perhaps as a way to make orchestration runs more visible and observible and measurable and improvable. In contrast to issues, milestones, prs, etc orchestration sessions should have some kind of artifact to track and measure and improve. Similar general method to the groom skill report. — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1034 — (groom): fix report and dry-run fidelity — bot-owned rows, label PLAN detail, refusal and pty test coverage — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1033 — (groom): harden outcomes handling — dataset identity, missing-file opt-in, lost-record exit code, render tests — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1030 — (integrate): prior-trigger detection on reconstruct cannot bound a trigger that predates every server-side signal — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1029 — (retro): a run whose only marker was edited after the --as-of cutoff reports not-found instead of indeterminate — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1023 — (orchestrator): plan.json attributable operator override for policy/dispatcher changes across revisions — title exceeds 100 characters (proposed fix: a retitle plan row)
- #1022 — (retro): re-verify historical run records with their recorded rounds policy, not the live .devflow.toml caps — title exceeds 100 characters (proposed fix: a retitle plan row)
- #995 — (dev-flow-stats): repository-wide metrics and replay should discover current-marker runs and consume a record directory — title exceeds 100 characters (proposed fix: a retitle plan row)
- #994 — (retro): Evidence-only and integrity output should carry discovery anomalies, the as-of cutoff, and verification gaps — title exceeds 100 characters (proposed fix: a retitle plan row)
- #990 — (retro): a PR-only evidence marker with no local record is invisible to the targeted --run invocation — title exceeds 100 characters (proposed fix: a retitle plan row)
- #942 — (devflow): per-finder model/effort overrides, and make task challenge/review honour the resolved policy — title exceeds 100 characters (proposed fix: a retitle plan row)
- #921 — (dev-flow): Rename the plan-approved strategy to say who approves (plan-ask, plan-gated, plan-then-approve) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #908 — (dev-flow): Decide whether deferred findings need a dedicated state/memory store (sidecar.md) beyond GitHub issues — title exceeds 100 characters (proposed fix: a retitle plan row)
- #877 — (dev-flow runtime): runtime manifest, atomic skills-sync install, offline verification, and /orchestrate preflight — residue after #974 — malformed issue title (proposed fix: a retitle plan row)
- #877 — (dev-flow runtime): runtime manifest, atomic skills-sync install, offline verification, and /orchestrate preflight — residue after #974 — title exceeds 100 characters (proposed fix: a retitle plan row)
- #856 — (shepherd): document the deferred-finding outcome grammar and add a token for open-question dispositions — title exceeds 100 characters (proposed fix: a retitle plan row)
- #855 — (implement): ship a brief template that carries gate bounds, the stop-at-draft rule, and the proposal-only clause — title exceeds 100 characters (proposed fix: a retitle plan row)
- #854 — (dev-flow): Consider a prompt-registry JSON that declares and validates per-harness, per-role prompts — title exceeds 100 characters (proposed fix: a retitle plan row)
- #802 — (skills): Add a /learn skill that turns a correction into a dev-loop change (memory, artifact, or .devflow.toml setting) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #716 — (verify): make the verify gate faster and lighter — shellcheck memory, load flakiness, parallel-lane contention — title exceeds 100 characters (proposed fix: a retitle plan row)
- #712 — (session-flow): Record a timestamp in kickoff, claim, and implement so wall-clock time per stage can be computed — title exceeds 100 characters (proposed fix: a retitle plan row)
- #614 — (standardize-repo): Harden the vendored-skills state model — legacy stamps, byte drift, offline classify, yq fallback — title exceeds 100 characters (proposed fix: a retitle plan row)
- #981 — (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR — title exceeds 100 characters (proposed fix: a retitle plan row)
- #561 — Dependency Dashboard — malformed issue title (proposed fix: a retitle plan row)
- #527 — (docs): Document the git check-ref-format --branch shorthand-expansion gotcha in worktree/validation guidance — title exceeds 100 characters (proposed fix: a retitle plan row)
- #510 — (gauntlet): Gauntlet §8: state the converse — a log that stops growing is the hang signal, not patience — title exceeds 100 characters (proposed fix: a retitle plan row)
- #501 — (shepherd): Probe mergeStateStatus before reserving a Codex cycle — BEHIND wastes a full review cycle — title exceeds 100 characters (proposed fix: a retitle plan row)
- #472 — (shepherd): Document the workflow_dispatch fallback when GitHub never creates the pull_request check suite — title exceeds 100 characters (proposed fix: a retitle plan row)
- #468 — (shepherd): Extend the gate-verdict marker rule from pushes to all gate-chained writes (commits included) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #467 — (integrate): Preflight the gh login before posting Codex triggers — unauthorized triggers present as a reviewer outage — title exceeds 100 characters (proposed fix: a retitle plan row)
- #435 — (wrap): Sweep what a long session leaves behind — stale branches, cycle state, deferred notes, recordless claims — title exceeds 100 characters (proposed fix: a retitle plan row)
- #428 — (standardize-repo): Verify GitHub-side prerequisites, empirically — four shipped automations were inert — title exceeds 100 characters (proposed fix: a retitle plan row)
- #422 — (skills): Nothing stops a skill's Markdown accumulating an unshipped program — audit is clean today, add the guard — title exceeds 100 characters (proposed fix: a retitle plan row)
- #417 — (standardize-repo): copier can merge a template file into an incoherent, marker-less state that update cannot triage — title exceeds 100 characters (proposed fix: a retitle plan row)
- #416 — (standardize-repo): diff-template's OWNED derivation uses yq + check-ignore, not copier's own loader/matcher — title exceeds 100 characters (proposed fix: a retitle plan row)
- #415 — (shepherd): Watch loops can stall forever on a zombie check run whose parent workflow run already concluded — title exceeds 100 characters (proposed fix: a retitle plan row)
- #407 — (skills): Test-skills.sh leaks its whole temp tree per run, until the disk fills and assertions fail spuriously — title exceeds 100 characters (proposed fix: a retitle plan row)
- #404 — (shepherd): Readiness gate can pass on revoked reaction evidence — bind trigger reactions into the fingerprint — title exceeds 100 characters (proposed fix: a retitle plan row)
- #398 — (standardize-repo): Native skills-source detection omits require-marker.sh, so a partial vendor passes — title exceeds 100 characters (proposed fix: a retitle plan row)
- #344 — (dev-flow): Carry harmon-init#710 (P1): SessionStart hook trusts the clone's origin, not the checked-out revision — title exceeds 100 characters (proposed fix: a retitle plan row)
- #342 — (skills): Decide this repo's use_skills_sync posture — sync:skills cannot run against its own symlinked skills — title exceeds 100 characters (proposed fix: a retitle plan row)
- #310 — (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from — title exceeds 100 characters (proposed fix: a retitle plan row)
- #305 — (implementer): Backgrounding the exit gate makes §5 and §7 unsatisfiable — a subagent has no next turn to collect it — title exceeds 100 characters (proposed fix: a retitle plan row)
- #289 — (track-work): The closing-keywords guard ignores the Refs path, where ticks are the only record of partial progress — title exceeds 100 characters (proposed fix: a retitle plan row)
- #284 — (agents): G — Permanent guards: zizmor + scheduled conversation scan + revision-deletion habit [AGENT] — title exceeds 100 characters (proposed fix: a retitle plan row)
- #280 — (agents): C — Identifier denylist decision + shipped-content sweep + lint:leakage guard [AGENT+HUMAN] — title exceeds 100 characters (proposed fix: a retitle plan row)
- #254 — (agents): Verify-agents/verify-skills approximate YAML in awk, so 'valid' can mean something a loader rejects — title exceeds 100 characters (proposed fix: a retitle plan row)
- #246 — (tests): awk-portability regressions in shipped assets are invisible to CI (gawk on runners, mawk in devcontainer) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #221 — (session-flow): Format statuses, reports, outcomes, and tables per session state (orient, retro, close, PRs) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #209 — (dev-flow): The manifest sets a coverage floor but no ceiling, so off-diff P1s make a clean re-run unreachable — title exceeds 100 characters (proposed fix: a retitle plan row)
- #204 — (standardize-repo): Diff-template.sh renders with --trust on the host, and dropping --trust would not fix it — title exceeds 100 characters (proposed fix: a retitle plan row)
- #201 — (skills): Identity checks must name their authority — the same 'trust the payload' defect appeared three times in one PR — title exceeds 100 characters (proposed fix: a retitle plan row)
- #198 — (standardize-repo): Carry two P1 defects from harmon-init v4.8.1 — adopt the fixes for harmon-init#412 and #461 — title exceeds 100 characters (proposed fix: a retitle plan row)
- #194 — (dev-flow): Scripts/shell-quality.sh is an orphan of the template's format-shell.sh + lint-shell.sh split — title exceeds 100 characters (proposed fix: a retitle plan row)
- #193 — (standardize-repo): Verify-applied's unrendered-marker scan false-positives on jinja-named test fixtures — title exceeds 100 characters (proposed fix: a retitle plan row)
- #188 — (dev-flow): The stale-reference check is scoped to the files the issue names, so a third stale copy survives — title exceeds 100 characters (proposed fix: a retitle plan row)
- #186 — (standardize-repo): mode-update validates repo identity only after the PR merges; rollback snapshot stops at 30 repos — title exceeds 100 characters (proposed fix: a retitle plan row)
- #7 — (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.) — title exceeds 100 characters (proposed fix: a retitle plan row)
- #5 — (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights) — title exceeds 100 characters (proposed fix: a retitle plan row)

## Bot-owned issues (excluded from retitle/close/relabel)

- #561 — Dependency Dashboard
- #127 — (deps): Dependency Dashboard

## Every issue

| # | Title | Verdict | Priority | Group | Status |
| --- | --- | --- | --- | --- | --- |
| #92 | (design-handoff-skill): Add Stripe account logo | KEEP | p3 | design/account | PENDING |
| #150 | (standardize-repo): Orphan sweep drowns in .app bundle internals | KEEP | p2 | standardization/update | PENDING |
| #181 | (standardize-repo): §6 covers authoring conditionally-named files, not reading them | KEEP | p3 | standardization/docs | PENDING |
| #186 | (standardize-repo): mode-update validates repo identity only after the PR merges; rollback snapshot stops at 30 repos | KEEP | p1 | standardization/update | PENDING |
| #193 | (standardize-repo): Verify-applied's unrendered-marker scan false-positives on jinja-named test fixtures | KEEP | p2 | standardization/verification | PENDING |
| #204 | (standardize-repo): Diff-template.sh renders with --trust on the host, and dropping --trust would not fix it | KEEP | p1 | standardization/security | PENDING |
| #370 | (dev-flow): Four diff-template sweep cases fail locally on macOS while CI verify is green | KEEP | p1 | delivery/portability | PENDING |
| #397 | (standardize-repo): The trigger-phrase detector is a heuristic duplicated across two repos | KEEP | p2 | delivery/lint | PENDING |
| #398 | (standardize-repo): Native skills-source detection omits require-marker.sh, so a partial vendor passes | KEEP | p2 | standardization/skills-runtime | PENDING |
| #401 | (standardize-repo): Index-state and mode-detection follow-ups from the 400 review rounds | KEEP | p2 | standardization/diff | PENDING |
| #416 | (standardize-repo): diff-template's OWNED derivation uses yq + check-ignore, not copier's own loader/matcher | KEEP | p2 | standardization/diff | PENDING |
| #417 | (standardize-repo): copier can merge a template file into an incoherent, marker-less state that update cannot triage | KEEP | p2 | standardization/update | PENDING |
| #420 | (standardize-repo): Update mode's guarded recipe ships as prose, not as a runnable asset | KEEP | p1 | standardization/fleet | PENDING |
| #428 | (standardize-repo): Verify GitHub-side prerequisites, empirically — four shipped automations were inert | KEEP | p1 | standardization/reconcile | PENDING |
| #536 | (triage): Track backlog findings | KEEP | p3 | tracker/standing-reports | PENDING |
| #561 | Dependency Dashboard | KEEP | p3 | delivery/dependencies | PENDING |
| #577 | (standardize-repo): Couple confirm-answers --check to the copier run | KEEP | p2 | standardization/update | PENDING |
| #614 | (standardize-repo): Harden the vendored-skills state model — legacy stamps, byte drift, offline classify, yq fallback | KEEP | p2 | standardization/skills-runtime | PENDING |
| #616 | (test): make the standardize scratch-rehearsal assertion concurrency-safe | KEEP | p3 | delivery/test-reliability | PENDING |
| #667 | (standardize-repo): Accept date-named ADRs in the decisions audit | CLOSE-done | p2 | standardization/decisions | PENDING |
| #687 | (ci): Vendor release-claim.sh onto the claim-release runner or fail the sync loudly | KEEP | p2 | delivery/claims | PENDING |
| #696 | (tests): Run test-confirm-answers under an explicit umask | KEEP | p2 | delivery/test-reliability | PENDING |
| #704 | (tests): Distinguish grep failure from no-match in fixture assertions | KEEP | p2 | delivery/test-reliability | PENDING |
| #716 | (verify): make the verify gate faster and lighter — shellcheck memory, load flakiness, parallel-lane contention | NEEDS-DECISION | p1 | delivery/gate-performance | PENDING |
| #798 | (dev-flow-stats): model default-branch transitions in registry revision landing | KEEP | p2 | delivery/evidence-trust | PENDING |
| #838 | (tests): close the reporter-check structural corners in lint-shell-robustness | KEEP | p2 | delivery/lint | PENDING |
| #848 | (tests): model the remaining grep invocation spellings in lint-shell-robustness | KEEP | p2 | delivery/lint | PENDING |
| #858 | (standardize-repo): run task audit:ruleset in the fleet audit and report drift as advisory | KEEP | p2 | standardization/reconcile | PENDING |
| #898 | (ci): Add test:dev-flow-monitor to build.yml test matrix | CLOSE-done | p2 | delivery/ci-parity | PENDING |
| #901 | (hooks): Add SIGPIPE-reproducing test coverage for hook scripts | KEEP | p2 | delivery/hooks | PENDING |
| #907 | (consumer-pin-audit): Follow-up P2 hardening from the #859 review | KEEP | p2 | delivery/consumer-audit | PENDING |
| #1052 | (docs): Decide one routine for keeping documentation and notes fresh instead of three overlapping ideas | KEEP | p3 | docs/maintenance | PENDING |
| #1053 | (standardize-repo): Sweep the standards catalog, checklist, and mode-update for drift in one pass | KEEP | p2 | standardization/docs | PENDING |
| #1054 | (tests): Close the remaining lint-shell-robustness coverage gaps | KEEP | p2 | delivery/lint | PENDING |
| #1082 | (scripts): Consolidate the three BSD/GNU sed in-place idioms into one write-through helper under scripts/lib | KEEP | p3 | delivery/portability | PENDING |
| #1109 | (ci): Audit what task verify runs against what CI runs, and define what gates a merge | KEEP | p2 | delivery/ci-parity | PENDING |
| #1159 | (integrate): make integrator passes immutable and their Codex verdicts self-authenticating | KEEP | p1 | delivery/evidence-trust | PENDING |
| #1172 | (standardize-repo): Install wrangler in the web-astro/web-app scaffold commands | KEEP | p2 | standardization/scaffolding | PENDING |
| #1208 | (skills): Inject the diff-template evaluator failure in a way git 2.43 exercises too | KEEP | p2 | delivery/portability | PENDING |
| #1254 | (decisions): Rename the numbered ADRs to the date form and repoint the mutable harmon-init link | KEEP | p2 | docs/decisions | PENDING |
| #1483 | (ci): Require the actual verifier in split-suite parity checks | KEEP | p2 | delivery/ci-parity | PENDING |
| #1488 | (standardize-repo): Close six verify-applied aggregate-parser edge cases left by #966 | KEEP | p2 | standardization/verification | PENDING |
| #1531 | (standardize-repo): Provision the model labels before the draft PR instead of after merge | KEEP | p1 | standardization/reconcile | PENDING |
| #1533 | (standardize-repo): Check the skills pin against the target release's minimum before applying | KEEP | p1 | standardization/skills-runtime | PENDING |
| #1535 | (standardize-repo): Split mode-update.md into a short runbook and on-demand references | KEEP | p2 | standardization/docs | PENDING |
| #1537 | (standardize-repo): Read fleet-run rulings from one versioned decisions file | KEEP | p2 | standardization/fleet | PENDING |
| #1585 | (standardize-repo): test-skills verify-applied aggregate cases fail on macOS at a clean main | KEEP | p1 | delivery/portability | PENDING |
| #1657 | (fleet): Run standardize-repo across the managed fleet in waves | KEEP | p1 | standardization/fleet | PENDING |
| #1658 | (reconcile): Standardize each repo's GitHub-side configuration from the template | KEEP | p1 | standardization/reconcile | PENDING |
| #1659 | (review-scope): Review only the application of the template, and keep skills pins at the release minimum | KEEP | p2 | standardization/review-scope | PENDING |
| #1665 | (standardize-repo): Ask a fixed start-of-run question set and record the answers in the fleet decisions file | KEEP | p2 | standardization/fleet | PENDING |
| #1666 | (standardize-repo): Default the slash command to a fleet run built from the inventory, with waves by owner | KEEP | p2 | standardization/fleet | PENDING |
| #1667 | (standardize-repo): Keep a per-run fleet report on the epic and a per-repo report on each tracking issue | KEEP | p2 | standardization/fleet | PENDING |
| #1668 | (standardize-repo): Derive required render variables from the answers instead of stopping for them | KEEP | p2 | standardization/update | PENDING |
| #1669 | (standardize-repo): Run the GitHub-side reconcile phase in every mode, probing in lanes and writing from the parent | KEEP | p1 | standardization/reconcile | PENDING |
| #1670 | (standardize-repo): Report each repo's devcontainer definition, CI image and staleness, and queue rebuilds | KEEP | p2 | standardization/fleet | PENDING |
| #1672 | (standardize-repo): Write the PR review-scope section and the PR-bot reviewer scope from one source | KEEP | p2 | standardization/review-scope | PENDING |
| #1673 | (standardize-repo): Handle open skills-sync PRs and the release-minimum pin before updating | KEEP | p2 | standardization/skills-runtime | PENDING |
| #1677 | (standardize-repo): Fail the audit when renovate.json drifts from the template render | KEEP | p2 | standardization/reconcile | PENDING |
| #1685 | fix(standardize-repo): finish the split-jobs vocabulary and make gate reachability leaf-based | KEEP | p2 | standardization/docs | PENDING |
| #1689 | (standardize-repo): Report Renovate health and apply the release's toolchain floors per repo | KEEP | p2 | standardization/fleet | PENDING |
| #1707 | fix(standardize-repo): finish the rigor-label retirement and domain-extension steps | KEEP | p3 | standardization/docs | PENDING |
| #1712 | (standardize-repo): Authenticate the frozen-render bundle that decides standardize review exclusions | KEEP | p2 | standardization/review-scope | PENDING |
| #1721 | (devcontainer): test-devcontainer-git-ownership uses GNU stat -c and fails on macOS | KEEP | p1 | delivery/portability | PENDING |
| #1724 | (standardize-repo): Let a fleet decision supersede another and refuse citing a superseded one | KEEP | p2 | standardization/fleet | PENDING |
| #127 | (deps): Dependency Dashboard | KEEP | p2 | deps | PENDING |
| #191 | (track-work): A Verify block can be stricter than the criterion it stands for | KEEP | p2 | track-work/authoring | PENDING |
| #289 | (track-work): The closing-keywords guard ignores the Refs path, where ticks are the only record of partial progress | KEEP | p2 | track-work/progress | PENDING |
| #306 | (track-work): A Verify block whose pass condition is 'no output' fails open | KEEP | p2 | track-work/authoring | PENDING |
| #313 | (track-work): Set-issue-status.sh is host-naive — Projects V2 writes go to the default host | KEEP | p1 | track-work/host-binding | PENDING |
| #481 | (triage): Paginate scan and report lookups past the fixed windows | KEEP | p2 | triage/reporting | PENDING |
| #482 | (triage): Post-write verification for concurrent label and report writes | KEEP | p2 | triage/concurrency | PENDING |
| #483 | (triage): Sandbox the headless worker beyond permission rules | KEEP | p1 | triage/isolation | PENDING |
| #484 | (triage): Persist inapplicable-axis attestations durably | NEEDS-DECISION | p2 | triage/registry | PENDING |
| #486 | (triage): Recompute report entries and ages from post-write state | KEEP | p2 | triage/reporting | PENDING |
| #503 | (track-work): Normalize backticked branch values in claim records | KEEP | p2 | track-work/claims | PENDING |
| #513 | (dev-flow): Detect whitespace-bearing tracked paths in rot evidence | KEEP | p2 | track-work/authoring | PENDING |
| #524 | (dev-flow): Union same-prefix family values before flagging unknown axis labels | KEEP | p3 | triage/registry | PENDING |
| #525 | (dev-flow): Refuse truncated live label pages in the metadata fallback vocabulary | CLOSE-done | p2 | track-work/metadata | PENDING |
| #553 | (track-work): Support host-qualified metadata checks | CLOSE-done | p2 | track-work/host-binding | PENDING |
| #579 | (claim): Clear or report pre-record claim markers on close | NEEDS-DECISION | p2 | track-work/claims | PENDING |
| #586 | (triage): Ship a task triage wrapper that sets TRIAGE_EXECUTE | KEEP | p2 | triage/runtime | PENDING |
| #589 | (triage): Ship a generator for the deterministic report entries | KEEP | p2 | triage/reporting | PENDING |
| #590 | (track-work): Document re-scoping the title after gh issue transfer | KEEP | p2 | track-work/authoring | PENDING |
| #591 | (track-work): Guard managed issues and structured titles in retitles | KEEP | p2 | track-work/titles | PENDING |
| #626 | (track-work): Lock completed-tick allowlist boundary | KEEP | p2 | track-work/progress | PENDING |
| #627 | (track-work): Define post-merge criterion close transition | NEEDS-DECISION | p2 | track-work/progress | PENDING |
| #631 | (track-work): Allow a planning profile without a Verify section | KEEP | p2 | track-work/authoring | PENDING |
| #640 | (retro): Render the retro status tables from status JSON | KEEP | p2 | dev-flow/retro | PENDING |
| #671 | (triage): Surface apparently completed open issues for review | NEEDS-DECISION | p2 | triage/completion | PENDING |
| #680 | (triage): Reuse the shared rendered-Markdown parser for completion-candidate criteria | KEEP | p2 | triage/completion | PENDING |
| #865 | (skills): Update track-work claim lifecycle for event-driven merged PR releases | KEEP | p2 | track-work/claims | PENDING |
| #871 | (track-work): Check issue metadata without a matching local clone | KEEP | p2 | track-work/metadata | PENDING |
| #883 | (track-work): A closing parent strands its native sub-issues open | NEEDS-DECISION | p2 | track-work/progress | PENDING |
| #930 | (labels): Single-source the registry_set enum and prefix map | KEEP | p3 | labels/registry | PENDING |
| #975 | (track-work): Stop accepting assignment as proof of write access | KEEP | p1 | track-work/claims | PENDING |
| #981 | (skills): Add a skill that scans and batches related bugs into one session or PR instead of one issue per PR | KEEP | p3 | groom/structure | PENDING |
| #1015 | (skills): Add a groom skill: verify, dispose, regroup, and record decisions across a backlog | NEEDS-DECISION | p2 | groom/lifecycle | PENDING |
| #1033 | (groom): harden outcomes handling — dataset identity, missing-file opt-in, lost-record exit code, render tests | KEEP | p2 | groom/reliability | PENDING |
| #1034 | (groom): fix report and dry-run fidelity — bot-owned rows, label PLAN detail, refusal and pty test coverage | KEEP | p2 | groom/reporting | PENDING |
| #1035 | (groom): persist subagent process findings through the join with --process-findings | KEEP | p2 | groom/reporting | PENDING |
| #1036 | (skills): grant scoped Write in allowed-tools where a universal skill's recipe writes local files | KEEP | p2 | skills/runtime | PENDING |
| #1037 | (groom): bind the headless audit worker's reads to the checkout and the resolved repository | KEEP | p1 | groom/isolation | PENDING |
| #1039 | (groom): host-qualify gh calls and preflight sub-issue and milestone permissions in apply | KEEP | p1 | groom/host-binding | PENDING |
| #1040 | (groom): canonicalize the run directory and validate group, proposals, and sub-issue rows | KEEP | p2 | groom/reliability | PENDING |
| #1047 | (track-work): Host-qualify every GitHub write path so a wrong host or missing scope is refused before writing | KEEP | p2 | track-work/host-binding | PENDING |
| #1048 | (track-work): Make Verify blocks fail closed — one authoring rule for no-output and planning-profile checks | KEEP | p2 | track-work/authoring | PENDING |
| #1049 | (triage): Settle the deferred findings from the triage v1 review (PR #480 and #523) | KEEP | p2 | triage/hardening | PENDING |
| #1066 | (groom): Follow-ups from the first supervised groom run (2026-09-15) | KEEP | p2 | groom/lifecycle | PENDING |
| #1085 | (skills): Add an opt-in live test that runs the wrappers' real permission grants through the installed Claude CLI | KEEP | p2 | skills/runtime | PENDING |
| #1087 | (triage): Run the report half of triage weekly from a workflow, keeping label writes supervised | KEEP | p2 | triage/automation | PENDING |
| #1088 | (groom): Decide and implement a durable destination for the groom report | NEEDS-DECISION | p2 | groom/publishing | PENDING |
| #1182 | (track-work): Release a claim placed on a follow-up issue when the filing lane wraps | KEEP | p2 | track-work/claims | PENDING |
| #1187 | (issue-title-support): Keep unknown org native types in triage | KEEP | p2 | triage/classification | PENDING |
| #1205 | (groom): Let a spec-worthy theme name a planning vehicle the repository actually uses | NEEDS-DECISION | p2 | groom/structure | PENDING |
| #1227 | (triage): Reconcile collector items against source follow-up lines | KEEP | p2 | tracker/collectors | PENDING |
| #1228 | (groom): Apply an approved move of human follow-ups to their collector | KEEP | p2 | tracker/collectors | PENDING |
| #1229 | (breakdown): Cite new collectors by number from the chunks they serve | KEEP | p2 | tracker/collectors | PENDING |
| #1231 | (track-work): Require human and umbrella on collector titles | CLOSE-done | p2 | tracker/collectors | PENDING |
| #1233 | (track-work): Bind collector scope reads and handle a last moved criterion | KEEP | p2 | tracker/collectors | PENDING |
| #1498 | (track-work): Close three gaps in tick-criteria's PR-reference authorisation left by #290 | KEEP | p2 | track-work/progress | PENDING |
| #1501 | (triage): Treat a plan another actor already satisfied as success, not a changed issue | KEEP | p1 | triage/concurrency | PENDING |
| #1556 | (track-work): cover gh api issue creation in the receipt guard | KEEP | p2 | track-work/receipts | PENDING |
| #1562 | (track-work): harden the receipt guard for relationship flags, org issue types and stale receipts | KEEP | p2 | track-work/receipts | PENDING |
| #1609 | fix(track-work): refuse wrong-case ratings before filing and tighten file-review-finding follow-ups | KEEP | p2 | track-work/review-findings | PENDING |
| #1612 | fix(dev-flow-support): skip needs-review cleanup for replayed events older than the label | KEEP | p2 | track-work/claims | PENDING |
| #1676 | (track-work): Store issue receipts under the --repo-root checkout | KEEP | p1 | track-work/receipts | PENDING |
| #1678 | (track-work): Route verification steps to (QA) and actions to (HUMAN) collectors | KEEP | p2 | tracker/collectors | PENDING |
| #1693 | (skills): Align groom, triage and track-work on epics, collectors, and where each issue belongs | KEEP | p2 | tracker/structure | PENDING |
| #276 | (shepherd): Something promotes drafts out of the readiness gate's control, 9+ times in one session | KEEP | p1 | integration/lifecycle | PENDING |
| #404 | (shepherd): Readiness gate can pass on revoked reaction evidence — bind trigger reactions into the fingerprint | KEEP | p2 | integration/review-safety | PENDING |
| #408 | (shepherd): No vendored helper for the merge-base-and-re-verify round when mergeStateStatus is DIRTY | KEEP | p2 | integration/review-safety | PENDING |
| #411 | (shepherd): Shepherd carry: freshness gate refuses evidence check | CLOSE-done | p1 | integration/review-safety | PENDING |
| #415 | (shepherd): Watch loops can stall forever on a zombie check run whose parent workflow run already concluded | KEEP | p2 | integration/review-safety | PENDING |
| #419 | (shepherd): Shepherd check: carry acceptance ignores .state and | KEEP | p2 | integration/review-safety | PENDING |
| #467 | (integrate): Preflight the gh login before posting Codex triggers — unauthorized triggers present as a reviewer outage | KEEP | p2 | integration/review-safety | PENDING |
| #468 | (shepherd): Extend the gate-verdict marker rule from pushes to all gate-chained writes (commits included) | KEEP | p1 | integration/review-safety | PENDING |
| #472 | (shepherd): Document the workflow_dispatch fallback when GitHub never creates the pull_request check suite | KEEP | p2 | integration/review-safety | PENDING |
| #493 | (shepherd): Codify repeated-flip mode after the single-undo bound trips | KEEP | p2 | integration/lifecycle | PENDING |
| #496 | (shepherd): Unbraced $sha in push refspecs is mangled by zsh history modifiers | KEEP | p2 | integration/review-safety | PENDING |
| #501 | (shepherd): Probe mergeStateStatus before reserving a Codex cycle — BEHIND wastes a full review cycle | KEEP | p1 | integration/review-safety | PENDING |
| #516 | (shepherd): Establish PR-head upstream after the first exact-SHA push | KEEP | p2 | integration/review-safety | PENDING |
| #534 | (shepherd): Own cloud-review wait loop in shepherd skill | KEEP | p2 | integration/review-safety | PENDING |
| #578 | (shepherd): Paraphrase the Codex trigger string in report comments | KEEP | p2 | integration/review-safety | PENDING |
| #645 | (shepherd): Unify gated push protocols across shepherd and gauntlet | KEEP | p2 | integration/review-safety | PENDING |
| #648 | (shepherd): Record mid-stage cap changes and fix-without-cycle rounds | KEEP | p2 | integration/review-safety | PENDING |
| #651 | (shepherd): Diagnose a DIRTY head before waiting on absent checks | KEEP | p1 | integration/review-safety | PENDING |
| #669 | (shepherd): Write the claim-released record when releasing the label | CLOSE-obsolete | p2 | integration/lifecycle | PENDING |
| #673 | (shepherd): Settle prose-only P2 follow-ons in-thread | KEEP | p2 | integration/review-safety | PENDING |
| #683 | (shepherd): Count and disclose maintainer-authorized rounds past the cap | KEEP | p2 | integration/review-safety | PENDING |
| #762 | (shepherd): readiness-gate.sh never rechecks activity newer than the integrator result | KEEP | p1 | integration/evidence-and-accounting | PENDING |
| #801 | (dev-flow): Account for legacy merge-base integration budgets | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #803 | (integrate): Readiness gate accepts check runs that are not pull_request runs on the exact head | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #808 | (dev-flow): attribute remediation loops to the findings they answer | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #812 | (integrate): Audit-mode pass should name an unattributed promotion, not read as reconciled | KEEP | p3 | integration/evidence-and-accounting | PENDING |
| #820 | (integrate): Enforce invariant 10 on historical integrator passes (two-pass known-ID validation) | KEEP | p1 | integration/evidence-and-accounting | PENDING |
| #835 | (shepherd): List unanswered review threads and gate on them | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #856 | (shepherd): document the deferred-finding outcome grammar and add a token for open-question dispositions | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #857 | (shepherd): implement the marker-owned progress comment and marker-aware readiness fingerprinting | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #874 | (integrate): guide the shepherd to defer P2s rather than fix-repush on the final Codex cycle | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #912 | (integrate): Require --receipts in integration-stage readiness evaluation | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #948 | (integrate): Trusted-registry and state-cache trust boundary gaps (#804 deferred) | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #949 | (integrate): Finder_cycles validation and gate coverage gaps (#804 deferred) | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #950 | (integrate): Finder path test coverage and edge cases (#804 deferred) | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #976 | (integrate): Propagate the integrate-codex rename to its consumers | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #1030 | (integrate): prior-trigger detection on reconstruct cannot bound a trigger that predates every server-side signal | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #1071 | (integrate): audit a non-draft head promoted by the Codex plugin instead of requiring an undo | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #1111 | (integrate): Ship a polling asset for the stage's waits instead of hand-rolled monitors | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #1115 | fix(integrate): give a quota-exhausted Codex head a safe recovery route after exit 15 | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #1117 | feat(integrate): accept the Codex summary Completed row as terminal-clean under the head-binding invariants | KEEP | p2 | integration/evidence-and-accounting | PENDING |
| #1121 | (integrate): Run CI and review concurrently and batch fixes | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1126 | (integrate): an unbadged concern written as a bullet inside a self-fix summary still classifies informational | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1127 | (integrate): settled unbound badged comments never certify a head, so the cycle ends by escalation instead of clean | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1129 | (integrate): usage-limit substring test classifies a finding that quotes the quota message as quota exhaustion | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1130 | (integrate): a quota reply landing between attempt 1's snapshot and attempt 2's reservation is never seen | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1131 | (integrate): readiness-gate recheck treats a closed/merged PR (checker exit 14) as stale evidence | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1140 | (integrate): readiness gate reads only the first 100 closingIssuesReferences, so a body claiming more issues fails closing-linkage permanently | KEEP | p3 | integration/checker-and-readiness | PENDING |
| #1141 | (integrate): readiness gate does not re-verify closing linkage or base across the promotion window | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1142 | (integrate): the closing-target issue lookup classifies any object without pull_request as an issue without checking its identity | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1152 | fix(integrate): apply the charged/exempt pair and sum checks to finder_cycles[] | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1153 | fix(integrate): reap a run-spend sidecar orphaned by the quota-recovery path | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1175 | integrate: three fail-closed carry edge cases from #1163's final review cycle | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1177 | (integrate): Hold the readiness gate until every bot reviewer's findings are answered | KEEP | p1 | integration/checker-and-readiness | PENDING |
| #1180 | (integrate): Fall back to a Claude review after two incomplete Codex attempts | KEEP | p2 | integration/checker-and-readiness | PENDING |
| #1184 | (integrate): Support BSD base64 decode on macOS in trusted-registry.sh | CLOSE-obsolete | p3 | integration/review-lifecycle | PENDING |
| #1191 | (orchestrate): Reserve the last integration cycle for a recorded sibling-merge catch-up | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1218 | (integrate): Open the base-event window at the first attempt's request time | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1235 | (integrate): Carry the PR's adjudicated deferrals into the review trigger | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1257 | (integrate): re-gate a run whose promotion was reversed and whose head then moved | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1277 | (integrator): Report reviewer summaries, repeated declined comments and unsolicited finder comments without recording them as findings | KEEP | p2 | integration/role-dispatch | PENDING |
| #1279 | (integrate): Tell the orchestrator to dispatch each role agent on a model of its resolved tier | KEEP | p2 | integration/role-dispatch | PENDING |
| #1280 | (validate): Fail a role result whose producer tier departs from the resolved tier without a disclosure | KEEP | p1 | integration/role-dispatch | PENDING |
| #1283 | (integrate): Ship an integrator brief template that stops duplicate reads and verbatim reports | KEEP | p2 | integration/role-dispatch | PENDING |
| #1284 | (integrate): Add a command that assembles and validates the integrator result | KEEP | p2 | integration/role-dispatch | PENDING |
| #1293 | (integrate): Honour a per-reviewer cadence from .devflow.toml and support Gemini and Claude as PR-side finders | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1332 | (integrate): Harden the integration exit engine and readiness record checks after #1272 | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1349 | (integrate): Re-check PR draft state before gh-write-broker adopts an existing trigger | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1380 | fix(integrate): harden update-branch.sh against mid-call state, base and verifier changes | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1433 | (integrate): Refuse a registered evidence comment whose first line is not the canonical dev-flow-v2-evidence marker | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1463 | (integrate): ship a validated helper for the automatic draft-undo ledger | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1474 | (integrate): Hold the readiness gate when the PR body lacks the rendered policy-disclosure section | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1484 | (integrate): Harden reservation release for deleted triggers, run changes and resumed posts | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1491 | (integrate): Accept a terminal run record for first-adoption runs that intentionally publish no issue evidence | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1502 | (integrate): Let a token without checks-rollup access reach a Codex review with a representable result | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1508 | (integrate): let the readiness gate reach a verdict on Actions-only evidence when the token cannot read check runs | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1515 | (integrator): Never hand back while a poll runs and never reap during a dispatched cycle | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1532 | (integrate): Expect promotion-triggered workflows and bot notices in the post-promotion comparison | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1536 | (integrate): Publish PR-hosted run evidence on first-adoption runs so /retro can measure them | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1545 | (integrate): let policy declare a post-promotion exemption the promote command honours and records | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1584 | feat(integrate): request advisory Greptile reviews while draft and never gate on them | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1593 | (orchestrate/integrate): Request needed Codex review alongside CI after the queue head catches up | KEEP | p2 | integration/review-lifecycle | PENDING |
| #1605 | (integrate): Read check runs through a GitHub App installation token | KEEP | p1 | integration/evidence-and-gates | PENDING |
| #1630 | (integrate): Preserve checker-only cycle history when dispatching a later cycle | KEEP | p1 | integration/evidence-and-gates | PENDING |
| #1635 | (integrate): Restrict checker-only readiness to exact trigger comments and empty reviews | KEEP | p1 | integration/evidence-and-gates | PENDING |
| #1643 | (integrate): Document authenticated same-head retry recovery | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1648 | fix(integrate): attribute App-bound required commit statuses in the readiness gate | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1680 | (integrate): Reconcile legacy deferred checklists before handoff | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #1697 | (integrate): Give catch-up fixtures enough time under parallel load | CLOSE-done | p2 | integration/evidence-and-gates | PENDING |
| #1698 | (integrate): Keep readiness carry fixtures parseable on Bash 3.2 | CLOSE-done | p2 | integration/evidence-and-gates | PENDING |
| #1703 | (integrate): Prove claim-record lineage before releasing claim labels at handoff | KEEP | p2 | integration/evidence-and-gates | PENDING |
| #209 | (dev-flow): The manifest sets a coverage floor but no ceiling, so off-diff P1s make a clean re-run unreachable | KEEP | p2 | review/scope-and-publication | PENDING |
| #474 | (gauntlet): Re-fetch the base before the PR-open ritual | KEEP | p2 | review/scope-and-publication | PENDING |
| #488 | (gauntlet): Best-effort existing-PR check at the entry gate, before rounds push | KEEP | p2 | review/scope-and-publication | PENDING |
| #489 | (gauntlet): Resolve the per-round push preconditions — workflow triggers and AGENTS.md CI ordering | KEEP | p2 | review/runtime-and-push | PENDING |
| #502 | (gauntlet): Neutralize recursive submodule behavior in round pushes | KEEP | p2 | review/runtime-and-push | PENDING |
| #510 | (gauntlet): Gauntlet §8: state the converse — a log that stops growing is the hang signal, not patience | KEEP | p2 | review/runtime-and-push | PENDING |
| #518 | (gauntlet): Gate gauntlet final checks against the PR merge ref | KEEP | p2 | review/runtime-and-push | PENDING |
| #560 | (gauntlet): Document three ways mutation results lie and their guards | KEEP | p2 | review/runtime-and-push | PENDING |
| #564 | (gauntlet): Validate guarded-push inputs before running full gates | NEEDS-DECISION | p2 | review/runtime-and-push | PENDING |
| #603 | (gauntlet): Dispatch adjudicated findings to owning agents | KEEP | p2 | review/runtime-and-push | PENDING |
| #620 | (gauntlet): forbid tree edits and HEAD moves while push-round.sh gates | KEEP | p2 | review/runtime-and-push | PENDING |
| #641 | (review): Deduplicate findings across stages and coordinated PRs | KEEP | p2 | review/runtime-and-push | PENDING |
| #699 | (gauntlet): Detach reviewer rounds from harness time caps | KEEP | p2 | review/runtime-and-push | PENDING |
| #706 | (review): Add a stall watchdog to codex-review.sh | KEEP | p2 | review/runtime-and-push | PENDING |
| #707 | (gauntlet): Keep round-gate state outside /tmp | KEEP | p2 | review/runtime-and-push | PENDING |
| #721 | (devflow): implement the --repo-root git-diff adapter for loadLedger | KEEP | p2 | review/exit-proof | PENDING |
| #722 | (devflow): verify fallback attempt order in dev-flow-exit | KEEP | p2 | review/exit-proof | PENDING |
| #724 | (devflow): require registry-validated policy before computing an exit | NEEDS-DECISION | p1 | review/exit-proof | PENDING |
| #725 | (devflow): verify new-fingerprint claims against the change ledger | KEEP | p2 | review/exit-evidence | PENDING |
| #728 | (dev-flow-render): reject duplicate passes per finder/round | KEEP | p2 | review/exit-evidence | PENDING |
| #732 | (devflow-exit): require explicit slot on every consumed pass | KEEP | p2 | review/exit-evidence | PENDING |
| #735 | (dev-flow-exit): reject 5 malformed-evidence gaps in round assembly | KEEP | p1 | review/exit-evidence | PENDING |
| #742 | (dev-flow-exit): Enforce the whole-run wall-clock ceiling before advancing | KEEP | p2 | review/exit-evidence | PENDING |
| #743 | (dev-flow-exit): Verify deferred-P2 sidecar handoff before advancing | KEEP | p2 | review/exit-evidence | PENDING |
| #759 | (review): round-push.sh should allow a branch to legitimately update .gitleaksignore | KEEP | p2 | review/trusted-execution | PENDING |
| #782 | (devflow): Reject verification for inactive confidence stages | KEEP | p1 | review/trusted-execution | PENDING |
| #787 | (review): Reconcile read-only finders with envelope validation | KEEP | p2 | review/trusted-execution | PENDING |
| #791 | (review): Execute the round-push broker from the trusted merge-base closure | KEEP | p1 | review/trusted-execution | PENDING |
| #792 | (review): Render trusted blockers when exit verification is indeterminate | KEEP | p2 | review/trusted-execution | PENDING |
| #793 | (review): Execute exit evaluation from the trusted merge-base closure | KEEP | p1 | review/trusted-execution | PENDING |
| #809 | (review): Bind a local CodeRabbit pass to the round's resolved scope | KEEP | p2 | review/trusted-execution | PENDING |
| #811 | (review): Bind a dirty-worktree finder pass to an immutable snapshot | KEEP | p1 | review/trusted-execution | PENDING |
| #824 | (dev-flow): Make both pass/adjudication directions cross-stage over validated inputs | KEEP | p1 | review/trajectory-integrity | PENDING |
| #825 | (dev-flow): Validate the whole recorded transition graph, not only the two verify-skip shapes | KEEP | p1 | review/trajectory-integrity | PENDING |
| #826 | (dev-flow): Apply the declared clock-skew tolerance to the chronology bounds | KEEP | p2 | review/trajectory-integrity | PENDING |
| #831 | (devflow): Validate per-run finder selection before computing an exit | KEEP | p2 | review/trajectory-integrity | PENDING |
| #853 | (dev-flow): Make change-ledger provenance stage-aware and verifiable after a deletion | KEEP | p2 | review/trajectory-integrity | PENDING |
| #872 | (review): Provide a supported deferred-findings sidecar writer | KEEP | p2 | review/deferred-findings | PENDING |
| #878 | (dev-flow): Add Greptile to the supported review providers | NEEDS-INFO | p3 | review/provider-support | PENDING |
| #908 | (dev-flow): Decide whether deferred findings need a dedicated state/memory store (sidecar.md) beyond GitHub issues | NEEDS-DECISION | p3 | review/deferred-findings | PENDING |
| #955 | (review): Preserve validated findings across confidence rounds | KEEP | p2 | review/finding-carry | PENDING |
| #957 | (review): Support stage advance when the review cap is 0 | KEEP | p2 | review/trajectory-integrity | PENDING |
| #958 | (review): Bind stage advance to the active-generation run lock | KEEP | p1 | review/trajectory-integrity | PENDING |
| #959 | (review): run the reviewer outside the candidate checkout so candidate instructions cannot steer it | KEEP | p1 | review/trusted-execution | PENDING |
| #960 | (dev-flow): Bind brief envelopes to repository, registry, and run | KEEP | p2 | orchestration/brief-binding | PENDING |
| #980 | (dev-loop): Have the PR review agent post a mermaid diagram and an illustrative image for each PR | KEEP | p3 | review/presentation | PENDING |
| #1008 | (review loop): Make human transitions terminal and enforceable | KEEP | p1 | review/workflow-control | PENDING |
| #1009 | (review budget): Stop scope accretion at the round-two checkpoint | KEEP | p2 | review/workflow-control | PENDING |
| #1042 | (review): evidence_comments entries are written with null comment_id and actor_id after reconcile | CLOSE-done | p2 | review/evidence-publication | PENDING |
| #1056 | (review): Land the current-head review follow-ups deferred from PR #768 as one trust-boundary body of work | KEEP | p1 | review/trusted-execution | PENDING |
| #1067 | (round-push): skip the second task verify when a green receipt exists for the same tree | KEEP | p2 | review/push-gates | PENDING |
| #1112 | fix(review): derive round-push.sh's policy-reader path from the configured skills destination | KEEP | p2 | review/push-gates | PENDING |
| #1203 | (round-push): Prove -c overrides reach ls-remote and the push with a behavioural test | KEEP | p2 | review/push-gates | PENDING |
| #1242 | (review): record the finder's own badge as each envelope's priority | KEEP | p2 | review/finder-integrity | PENDING |
| #1358 | (review): Show later Codex rounds the findings already deferred so they are not re-raised | KEEP | p2 | review/finding-carry | PENDING |
| #1365 | (review): give Codex envelope mode a schema-enforcing, approval-never invocation | KEEP | p2 | review/finder-integrity | PENDING |
| #1366 | (review): local Codex review passes run with approval on-request, so reviewed content can request unsandboxed commands | KEEP | p2 | review/finder-integrity | PENDING |
| #1379 | (review): pass prior-round finding records to envelope-mode finders | KEEP | p2 | review/finding-carry | PENDING |
| #1383 | (review): bind envelope-mode governing inputs and the review tree to the captured head | KEEP | p1 | review/finder-integrity | PENDING |
| #1405 | (review): handle a generation change mid-publication and run ids that do not encode their issue | KEEP | p2 | review/evidence-publication | PENDING |
| #1412 | (review): harden post-evidence.sh publication against hung calls, a full comment scan and listing lag | KEEP | p2 | review/evidence-publication | PENDING |
| #1428 | (review): build or verify the published evidence projection from retained round evidence | KEEP | p2 | review/evidence-publication | PENDING |
| #1493 | (review): Resolve the repo root in test-post-evidence.sh without a fixed parent depth, so vendored copies work | KEEP | p2 | review/portable-tests | PENDING |
| #1516 | (review): Require a live probe when a change shapes an external CLI's arguments | KEEP | p2 | review/validation-guidance | PENDING |
| #1555 | (review): record the effective Codex reasoning effort of every finder pass | KEEP | p2 | review/finder-integrity | PENDING |
| #1583 | (review): clean up review checkouts left by interrupted finder runs | KEEP | p2 | review/recovery | PENDING |
| #608 | (herdr delegation): Add a supervised staged-agent handoff procedure | KEEP | p2 | orchestration/supervision | PENDING |
| #784 | (orchestrator): Bootstrap issue-bound dev-flow runs before dispatch | KEEP | p2 | orchestration/bootstrap | PENDING |
| #785 | (orchestrator): Bind assembly plans to the complete lane roster | KEEP | p2 | orchestration/assembly | PENDING |
| #790 | (orchestrator): Enforce strategy human gates around council actions | KEEP | p1 | orchestration/authorization | PENDING |
| #926 | (orchestrator): herdr pane-worker orchestration friction log (slate #2) | KEEP | p3 | orchestration/standing-log | PENDING |
| #1006 | (orchestrator): plan.json overlap surface should include each lane's accepted fence expansions | KEEP | p2 | orchestration/plan-integrity | PENDING |
| #1023 | (orchestrator): plan.json attributable operator override for policy/dispatcher changes across revisions | KEEP | p2 | orchestration/plan-integrity | PENDING |
| #1072 | (orchestrator): pre-authorise P2/P3 dispositions in lane briefs so lanes stop only on P0/P1 or a cap | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1076 | (orchestrator): archive the lane report into the run directory and prune active state on teardown | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1093 | (orchestrator): Resume lanes and reviewers after a session usage limit | KEEP | p1 | orchestration/supervision | PENDING |
| #1122 | (orchestrator): Delegate complete bounded remediation units | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1143 | (orchestrator): Carry the epic-991 lane-brief lessons in the template | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1145 | (orchestrate): lane-brief.md's own env-var rule is still categorical and forbids the release-title preflight inputs | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1146 | (orchestrate): lane-brief.md lacks the output-only startup BLOCKED handoff the base brief gained | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1156 | (orchestrate): digest evidence comments over the body as posted, and record the digest the harvester recomputes | CLOSE-done | p2 | orchestration/delegation-contract | PENDING |
| #1162 | (orchestrate): release a lane's claim with a trusted Claim released marker, not prose | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1165 | (orchestrator): Require an invariant-plus-self-check directive when consecutive review cycles repeat a finding class | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1167 | (orchestrator): Make the lane watcher and the post-trigger sweep see top-level bot review comments | KEEP | p2 | orchestration/supervision | PENDING |
| #1168 | (orchestrator): Freeze the PR head between a review trigger request and the cycle's terminal result | KEEP | p1 | orchestration/delegation-contract | PENDING |
| #1169 | (orchestrator): Verify a Codex prompt started a turn on the expected model before treating it as delivered | KEEP | p2 | orchestration/supervision | PENDING |
| #1181 | (orchestrate): Ship a lane-watch that returns on an idle settle ending in a question | KEEP | p2 | orchestration/supervision | PENDING |
| #1202 | (orchestrate): name the challenge/review envelope persistence path in the lane brief Codex section | KEEP | p2 | orchestration/delegation-contract | PENDING |
| #1210 | (orchestrate): Run lanes as Claude Code cloud sessions that Herdr can start, attach to, and watch | NEEDS-DECISION | p2 | orchestration/remote-lanes | PENDING |
| #1211 | (orchestrate): Default to Herdr tabs, per-lane harnesses, 3 parallel lanes, and standard rigor | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1213 | (orchestrate): Stop settle-wait re-reading completed runs on every poll | KEEP | p2 | orchestration/supervision | PENDING |
| #1215 | (orchestrate): Run lanes on Codex cloud and Fly.io Sprites from Herdr, as opt-in remote lanes | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1216 | (orchestrate): Count pull_request_target runs in settle-wait checks, or stop claiming to | KEEP | p1 | orchestration/supervision | PENDING |
| #1241 | (orchestrate): suppress the survey and size the window for Claude lanes | KEEP | p2 | orchestration/supervision | PENDING |
| #1246 | (orchestrate): Make PR post-promotion wait window configurable in devflow.toml | CLOSE-obsolete | p3 | orchestration/merge-queue | PENDING |
| #1270 | (orchestrate): Announce a merge order so a merge never lands on a sibling mid-cycle | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1271 | (orchestrate): State invariants in rulings and let the lane draft the wording | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1278 | (orchestrate): Let a lane continue past an empty confidence round without waiting for the orchestrator | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1288 | (orchestrate): Park supervision while only a human can move the run, and let lane-watch exit on the first terminal event | NEEDS-DECISION | p2 | orchestration/supervision | PENDING |
| #1290 | (orchestrate): Let Antigravity lanes run their gates without approvals, confirm prompt delivery, and stay in their own lane | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1296 | (orchestrate): Keep orchestrator state in the Git common directory and ship tested run-record and plan writers | NEEDS-DECISION | p2 | orchestration/durable-state | PENDING |
| #1297 | (orchestrate): Signal lane state through a structured status file instead of a matched report heading | KEEP | p1 | orchestration/supervision | PENDING |
| #1299 | (orchestrate): Revise the plan only when a base move touches a live fence or closes a slate issue | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1335 | (orchestrate): Report lane heads from git rev-parse and verify them before acting | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1395 | (orchestrate): Settle the cloud-lane P2 findings deferred from PR #1385 | KEEP | p2 | orchestration/remote-lanes | PENDING |
| #1416 | (orchestrate): make run-record init and canonical evidence posting the default at every rigor | KEEP | p1 | orchestration/evidence-publication | PENDING |
| #1417 | (orchestrator): claim for lanes only through claim-transaction.sh and validate the record at claim time | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1419 | (orchestrator): give Codex lanes a writable pnpm store and stage lane changes from git status | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1434 | (orchestrate): Record stage-transition notes in stage_transitions, never as interventions | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1435 | (orchestrate): Have the orchestrator attest the lane's model and effort in the brief for harnesses with no self-readable status line | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1514 | (orchestrate): Render the PR policy disclosure and post evidence only through the shipped helper | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1520 | (herdr): report agy panes as blocked while a permission prompt waits (upstream detection rule) | KEEP | p2 | orchestration/supervision | PENDING |
| #1523 | (orchestrate): ship the tooling a restarted orchestrator needs instead of scratchpad helpers | NEEDS-DECISION | p2 | orchestration/contracts-and-records | PENDING |
| #1527 | (orchestrate): derive lane fences from the validator scan at plan time and refuse incomplete ones | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1540 | (orchestrate): Check other sessions' open PRs before accepting a fence expansion | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1541 | (orchestrate): Name the finder as the pass envelope's producer in the lane brief | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1553 | (orchestrate): document a Codex lane launch that can commit from a linked worktree | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1564 | (orchestrate): harden lane-watch heartbeats, prompt episodes and sentinels for edge cases | KEEP | p2 | orchestration/supervision | PENDING |
| #1573 | (orchestrate): Record the implement transition when a lane is dispatched | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1574 | (lane brief): Hold a confidence round's fix push until the orchestrator records the round | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1575 | (lane brief): Name the configured finder slot and finding-id format for each confidence stage | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1576 | (orchestrate): make lane provisioning resumable, identifier-safe, re-briefing and remote-aware | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1578 | (orchestrate): give lane-watch an ownership lease and live spec reload | KEEP | p2 | orchestration/supervision | PENDING |
| #1579 | (orchestrate): Record a lane's stage transitions before its finder runs, so a pass is never dated before its stage | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1591 | (orchestrate): Serialize CI behind a merge queue; catch up only its head | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1603 | (orchestrate): Keep one merge-ready queue head, park the rest as drafts, and watch promoted PRs until merge | KEEP | p1 | orchestration/contracts-and-records | PENDING |
| #1651 | (orchestrate): Handle empty active-pointer directories on Bash 3.2 | KEEP | p2 | orchestration/supervision | PENDING |
| #1656 | (orchestrate): Add a lane teardown step for merged lanes, with no per-lane approval | KEEP | p2 | orchestration/contracts-and-records | PENDING |
| #1663 | (orchestrate): Accept an epic or umbrella issue as the slate input, using its sub-issues | KEEP | p2 | orchestration/slate-input | PENDING |
| #1664 | (orchestrate): Support multi-repo slates with a repository per issue and a clone per repository | KEEP | p2 | orchestration/slate-input | PENDING |
| #1682 | (orchestrate, integrate): Run pollers as bounded background passes, and fail loudly when gh or herdr is unreachable | KEEP | p1 | orchestration/observation | PENDING |
| #1688 | (orchestrate): Add a slated label that marks slate membership without claiming the issue | KEEP | p2 | orchestration/lifecycle | PENDING |
| #1692 | (orchestrate, implement): Clarify the one-write rule for lane-init, the path shorthand, and the solo recipe | KEEP | p3 | orchestration/procedure | PENDING |
| #1704 | (orchestrate): Enforce working and in-flight ceilings at dispatch, not in the static plan validator | KEEP | p1 | orchestration/admission | PENDING |
| #1719 | (orchestrate): test-provision-lane compares an unresolved /var temp path against the resolved /private/var one on macOS | KEEP | p2 | orchestration/tests | PENDING |
| #1722 | (orchestrate): Refuse to run vendored assets from a checkout behind the default branch | KEEP | p2 | orchestration/tool-freshness | PENDING |
| #1725 | (orchestrate): lane-watch keeps a HERDR-RECENT episode parked when explain proves it does not apply | KEEP | p3 | orchestration/observation | PENDING |
| #1728 | (orchestrate): Settle the lane-watch follow-ups deferred from #1726 | KEEP | p2 | orchestration/observation | PENDING |
| #727 | (devflow): define a schema for run receipts and slot failures | KEEP | p2 | records/schema-contract | PENDING |
| #729 | (renderer): four P2 hardening follow-ups from PR #719 cycle 5 | KEEP | p2 | records/renderer | PENDING |
| #730 | (devflow-policy): reject malformed registry collections, not crash | KEEP | p2 | policy/input-validation | PENDING |
| #731 | (toml-lite): reject incomplete exponent literals | KEEP | p2 | policy/input-validation | PENDING |
| #733 | (devflow-policy): reject non-string spend pointers, not disable | KEEP | p2 | policy/input-validation | PENDING |
| #734 | (devflow-policy): reject 8 malformed-input gaps in v2 resolution | KEEP | p2 | policy/input-validation | PENDING |
| #738 | (schemas): add seq/digest/prev_digest to run-record append-only arrays | KEEP | p2 | records/schema-integrity | PENDING |
| #752 | (dev-flow-stats): anchor evidence marker regex to comment start | KEEP | p2 | records/harvest-fidelity | PENDING |
| #754 | (dev-flow-stats): derive post-ready merge/deployment/release outcomes | KEEP | p2 | records/metrics | PENDING |
| #755 | (schemas): chain-protect run-record promotion contents | KEEP | p2 | records/schema-integrity | PENDING |
| #756 | (dev-flow-stats): canonicalize duplicate markers before orphan-report | KEEP | p2 | records/harvest-fidelity | PENDING |
| #757 | (dev-flow-stats): validate harvested records against run.schema.json | KEEP | p1 | records/validation | PENDING |
| #760 | (dev-flow-stats): timestamp when a commit joined its PR | KEEP | p2 | records/chronology | PENDING |
| #766 | (dev-flow-exit): add a retrospective mode for replay counterfactuals | KEEP | p2 | records/replay | PENDING |
| #769 | (dev-flow-stats): validate chain member shape before use | KEEP | p1 | records/validation | PENDING |
| #770 | (dev-flow-stats): validate nested round payload elements | KEEP | p1 | records/validation | PENDING |
| #771 | (dev-flow-stats): count promotion in isStale's activity check | KEEP | p2 | records/chronology | PENDING |
| #772 | (dev-flow-stats): score only the ready run and its predecessors | KEEP | p2 | records/metrics | PENDING |
| #774 | (dev-flow-stats): apply registry trust before index selection | CLOSE-done | p1 | records/trust | PENDING |
| #775 | (dev-flow-stats): reject duplicate run IDs across issues | KEEP | p2 | records/identity | PENDING |
| #776 | (dev-flow-stats): honor --as-of during policy replay | KEEP | p2 | records/replay | PENDING |
| #777 | (schemas): validate chronology for pr/outcome chain timestamps | KEEP | p1 | records/chronology | PENDING |
| #778 | (dev-flow-stats): fetch PR evidence from every bound PR | KEEP | p2 | records/harvest-fidelity | PENDING |
| #783 | (devflow): Bind recovered pushes to the named remote ref | KEEP | p1 | orchestration/push-authority | PENDING |
| #786 | (schemas): Bind synthesis provenance to implementer dispatch context | KEEP | p2 | records/dispatch-provenance | PENDING |
| #788 | (devflow): Canonicalize active branch identities | KEEP | p1 | orchestration/push-authority | PENDING |
| #789 | (renderer): Require source passes for every partial-blocker finding | KEEP | p1 | records/renderer | PENDING |
| #794 | (devflow): Make feature push authorization atomic with active-run ownership | KEEP | p1 | orchestration/push-authority | PENDING |
| #799 | (dev-flow-stats): close three per-write trust edge cases left at PR #797's shepherd cap | KEEP | p2 | records/trust | PENDING |
| #860 | (schemas): Close three deferred split-record validation gaps from #852 | KEEP | p2 | records/validation | PENDING |
| #913 | (stats): Require --receipts in dev-flow-stats validation | KEEP | p2 | records/validation | PENDING |
| #920 | (devflow): Decide pause-aware wall clock or extension protocol | NEEDS-DECISION | p2 | policy/time-budgets | PENDING |
| #942 | (devflow): per-finder model/effort overrides, and make task challenge/review honour the resolved policy | KEEP | p1 | policy/finder-resolution | PENDING |
| #977 | (dev-flow-stats): make the replay producer emit canonical receipts with authenticated chronology | KEEP | p2 | records/replay | PENDING |
| #995 | (dev-flow-stats): repository-wide metrics and replay should discover current-marker runs and consume a record directory | KEEP | p2 | records/discovery | PENDING |
| #1002 | (schemas): two stale rationale comments say receipts are absent from run.schema.json | KEEP | p3 | records/documentation | PENDING |
| #1024 | (schemas): mutation-test pattern keywords in test-result-schemas.sh across all kinds | KEEP | p2 | records/schema-tests | PENDING |
| #1025 | (schemas): timestamp comparisons in validate-result-schemas.mjs truncate sub-millisecond precision | KEEP | p2 | records/chronology | PENDING |
| #1026 | (schemas): apply the monitor-safe run_id pattern to run, adjudication, and envelope schemas | KEEP | p2 | records/schema-integrity | PENDING |
| #1055 | (schemas): Protect the run record's chain fields — original arrays plus promotion — as one schema change | KEEP | p2 | records/schema-integrity | PENDING |
| #1057 | (schemas): Apply the PR #1016 plan-validator hardening to the run, adjudication, and envelope schemas | KEEP | p2 | records/schema-integrity | PENDING |
| #1074 | (devflow-policy): derive the deep wall clock from the resolved caps, not a 480-minute constant | KEEP | p2 | policy/time-budgets | PENDING |
| #1128 | (schemas): validator verdict aggregation keeps a non-exact demand when an equal-rank exact one follows it | KEEP | p2 | records/validation | PENDING |
| #1161 | (dev-flow-stats): count remediation pushes against the remediation cap in run trajectories | CLOSE-done | p2 | records/metrics | PENDING |
| #1348 | (dev-flow-support): Validate integration cycle counters in dev-flow-exit before trusting the cap | KEEP | p1 | records/integration | PENDING |
| #1393 | (dev-flow-support): Govern the registry from the merge base when neither side has a .devflow.toml | KEEP | p1 | policy/governance | PENDING |
| #1394 | (dev-flow-stats): escape every Unicode line terminator in trajectory table rows | KEEP | p2 | records/retro | PENDING |
| #1398 | (dev-flow-support): Refuse replace refs and malformed two-argument flags on the merge-base governance path | KEEP | p2 | policy/governance | PENDING |
| #1438 | (plan schema): Let one orchestrated lane carry several issues in one PR | KEEP | p2 | records/plans | PENDING |
| #1445 | (dev-flow-support): let a solo run invalidate a stale unadjudicated pass instead of wedging the round | KEEP | p2 | records/solo | PENDING |
| #1460 | (dev-flow-exit): Let a declined false positive in a tell cycle not block a delete or restructure push | KEEP | p2 | records/integration | PENDING |
| #1473 | (dev-flow-support): Reject non-canonical run ids at plan, brief and run validation | KEEP | p2 | records/identity | PENDING |
| #1538 | (dev-flow-stats): Bound run lookup for IDs outside the canonical run-issue-slug format | KEEP | p2 | records/retro | PENDING |
| #1539 | (dev-flow plan schema): Let a later revision withdraw an accepted fence expansion | KEEP | p2 | records/plans | PENDING |
| #1568 | (dev-flow-support): refuse pre-token readers and re-check slate-lock ownership inside the write mutex | KEEP | p2 | records/ownership | PENDING |
| #1662 | (devflow): Add named run profiles so a skill or operator can select rigor, breadth and strategy together | KEEP | p2 | policy/profiles | PENDING |
| #1675 | (dev-flow-support): Record an orchestrator takeover's promotion on the lane's run | KEEP | p2 | records/lifecycle | PENDING |
| #1679 | (dev-flow-support): Record a maintainer-requested catch-up on a promoted run | KEEP | p2 | records/lifecycle | PENDING |
| #1690 | (schemas): Document strict integrator receipt validation context | KEEP | p2 | records/integration | PENDING |
| #254 | (agents): Verify-agents/verify-skills approximate YAML in awk, so 'valid' can mean something a loader rejects | NEEDS-DECISION | p2 | agents/validation | PENDING |
| #278 | (agents): A — Full-history secret scan [AGENT+HUMAN] | KEEP | p1 | security/open-source-audit | PENDING |
| #279 | (agents): B — Conversation-surface + edit-history scan [AGENT+HUMAN] | KEEP | p1 | security/open-source-audit | PENDING |
| #280 | (agents): C — Identifier denylist decision + shipped-content sweep + lint:leakage guard [AGENT+HUMAN] | NEEDS-DECISION | p1 | security/open-source-audit | PENDING |
| #281 | (agents): D — Workflow, fork, and Actions hardening audit [AGENT+HUMAN] | KEEP | p1 | security/open-source-audit | PENDING |
| #282 | (agents): E — Relicense to Apache-2.0 + support posture [AGENT+HUMAN] | KEEP | p2 | security/open-source-audit | PENDING |
| #284 | (agents): G — Permanent guards: zizmor + scheduled conversation scan + revision-deletion habit [AGENT] | KEEP | p2 | security/open-source-audit | PENDING |
| #305 | (implementer): Backgrounding the exit gate makes §5 and §7 unsatisfiable — a subagent has no next turn to collect it | KEEP | p2 | agents/gate-ownership | PENDING |
| #386 | (agents): Record that subagent briefs must demand foreground gate runs | KEEP | p2 | agents/gate-ownership | PENDING |
| #439 | (agents): A corrupt archive is never repaired — gzip -l failure exits 0 through the ERR trap | KEEP | p2 | agents/transcript-archive | PENDING |
| #440 | (agents): Archives accumulate without bound, and a full disk silently stops archiving | KEEP | p2 | agents/transcript-archive | PENDING |
| #441 | (agents): A recycled PID keeps a dead lock alive for up to an hour, silently skipping archives | KEEP | p2 | agents/transcript-archive | PENDING |
| #520 | (agents): Make agent pushes independent of interactive Git credentials | KEEP | p2 | agents/git-transport | PENDING |
| #559 | (agents): Preserve delegated gate ownership through completion | KEEP | p2 | agents/gate-ownership | PENDING |
| #615 | (implementer): direct delegated agents to run repo gates serially, not concurrently | KEEP | p2 | agents/gate-ownership | PENDING |
| #657 | (implementer): Keep driving a pending shepherd cycle instead of ending the turn | KEEP | p2 | agents/gate-ownership | PENDING |
| #717 | (implement): Rerun the one failing gate task alone twice instead of the full verify | NEEDS-DECISION | p2 | agents/gate-policy | PENDING |
| #855 | (implement): ship a brief template that carries gate bounds, the stop-at-draft rule, and the proposal-only clause | NEEDS-DECISION | p2 | agents/brief-contract | PENDING |
| #1132 | (agents): integrator thread classifier does not mirror the gate's self-report exemption | KEEP | p2 | agents/integration | PENDING |
| #1133 | (agents): integrator §7 assembly template hardcodes status completed, defeating the consecutive-16 blocked report | CLOSE-done | p2 | agents/integration | PENDING |
| #1147 | (implement): the dispatch procedure in implement/SKILL.md still performs the post-render placeholder scan the template replaced | KEEP | p2 | agents/brief-contract | PENDING |
| #1148 | (implement): hostile-title fixture does not exercise a backtick run as long as the code-span delimiter | KEEP | p2 | agents/brief-contract | PENDING |
| #1149 | (agents): the delegation contract's branch comparison needs a captured branch that read-only role dispatches do not supply | KEEP | p2 | agents/brief-contract | PENDING |
| #1150 | (agents): the delegation contract's scratch-directory rule binds the bounded integrator, whose brief has no such field | KEEP | p2 | agents/brief-contract | PENDING |
| #1166 | (implement): Extend the lane-brief PII rule to every pushed artifact and gate it per push | KEEP | p1 | agents/protected-data | PENDING |
| #1237 | (implement): Confirm each new entity kind’s scope, placement, and lifecycle | KEEP | p2 | agents/implementation | PENDING |
| #1281 | (agents): Give the integrator only the tools it uses so each pass starts smaller | KEEP | p2 | agents/context-budget | PENDING |
| #1282 | (agents): Move the integrator role file's rationale out of its system prompt | KEEP | p2 | agents/context-budget | PENDING |
| #1359 | (implement): Commit each round's fixes before the long verify run, push only after it passes | KEEP | p2 | agents/gate-policy | PENDING |
| #1378 | (agent-registry): reconcile copilot-cli harness roles with its registered challenge/review finders, and enforce one authority | NEEDS-DECISION | p2 | policy/registry | PENDING |
| #1414 | (implement): accept a lane's SHA-bound GATE-EXIT and skip the orchestrator's redundant verify | KEEP | p2 | agents/gate-policy | PENDING |
| #1421 | (implement): require a challenged design note before coding hard-tier state-machine changes | KEEP | p2 | agents/implementation | PENDING |
| #4 | (skills): Skill/loop/routine - holistic repo review | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #5 | (skills): Add a documentation/Obsidian holistic-review skill or routine (repo, action items, insights) | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #7 | (deps): Add an AI routine that automates dependency updates and the PR follow-ups they need (npm overrides etc.) | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #11 | (skills): Create skills for documenting, decision records, and their format/template | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #14 | (skills): SEO/GEO skill | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #15 | (skills): General product evaluation skill | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #16 | (skills): Documentation up to date skill | NEEDS-INFO | p3 | skills/incubator | PENDING |
| #17 | (skills): Logging, debugging, observability skill | KEEP | p3 | workflow/skill-authoring | PENDING |
| #18 | (deps): Dependency management skill | KEEP | p3 | workflow/skill-authoring | PENDING |
| #19 | (security): Security review/audit skill | KEEP | p3 | workflow/skill-authoring | PENDING |
| #20 | (skills): Review architecture and refactor until you're satisfied skill | KEEP | p3 | workflow/skill-authoring | PENDING |
| #114 | (skills): Load harmon-platform cross-repo context before architectural recommendations | KEEP | p2 | workflow/cross-repo-preflight | PENDING |
| #183 | (claim): Stale-claim sweep cannot find a claim whose only surviving markers are on the board | KEEP | p2 | workflow/claims | PENDING |
| #188 | (dev-flow): The stale-reference check is scoped to the files the issue names, so a third stale copy survives | KEEP | p2 | workflow/preflight | PENDING |
| #194 | (dev-flow): Scripts/shell-quality.sh is an orphan of the template's format-shell.sh + lint-shell.sh split | KEEP | p2 | workflow/toolchain | PENDING |
| #198 | (standardize-repo): Carry two P1 defects from harmon-init v4.8.1 — adopt the fixes for harmon-init#412 and #461 | KEEP | p1 | workflow/upstream-debt | PENDING |
| #201 | (skills): Identity checks must name their authority — the same 'trust the payload' defect appeared three times in one PR | KEEP | p2 | workflow/skill-authoring | PENDING |
| #207 | (skills): One rule is stated in six files with nothing checking they agree | KEEP | p2 | workflow/skill-authoring | PENDING |
| #221 | (session-flow): Format statuses, reports, outcomes, and tables per session state (orient, retro, close, PRs) | KEEP | p3 | workflow/reporting | PENDING |
| #246 | (tests): awk-portability regressions in shipped assets are invisible to CI (gawk on runners, mawk in devcontainer) | KEEP | p2 | workflow/toolchain | PENDING |
| #252 | (dev-flow): Add custom shell-quality rule forbidding   in grep patterns | KEEP | p2 | workflow/toolchain | PENDING |
| #258 | (skills): Verify ignores incoming-minus-managed, and a symlinked dest is followed out of the repo | KEEP | p1 | workflow/skills-sync | PENDING |
| #277 | (dev-flow): Open-source readiness audit (public-repo hardening) — rollup | KEEP | p2 | workflow/public-readiness | PENDING |
| #283 | (security): F — Enable public-repo security features [HUMAN] | KEEP | p2 | workflow/public-readiness | PENDING |
| #298 | (dev-flow): The cloud reviewer authored a commit on the branch it was reviewing | NEEDS-DECISION | p1 | workflow/reviewer-authorization | PENDING |
| #310 | (skills): Add a /council skill that spins up multiple candidate implementations for the orchestrator to choose from | KEEP | p3 | workflow/orchestration | PENDING |
| #316 | (skills): Implement skill: branch into a linked worktree by default | KEEP | p1 | workflow/worktree-isolation | PENDING |
| #342 | (skills): Decide this repo's use_skills_sync posture — sync:skills cannot run against its own symlinked skills | CLOSE-done | p2 | workflow/skills-sync | PENDING |
| #344 | (dev-flow): Carry harmon-init#710 (P1): SessionStart hook trusts the clone's origin, not the checked-out revision | KEEP | p1 | workflow/upstream-debt | PENDING |
| #360 | (test): Backtick inside an sh -c pattern hollows the rendered-target assertion | KEEP | p2 | workflow/test-reliability | PENDING |
| #377 | (skills): Trailing whitespace after name: causes a false mismatch on YAML-legal SKILL.md | KEEP | p2 | workflow/skills-validation | PENDING |
| #383 | (ci): Local shellcheck drifts from CI's, so task check passes heads CI then fails | KEEP | p2 | workflow/toolchain | PENDING |
| #390 | (dev-flow): Right-size gate depth to change risk — every change pays the full pipeline | KEEP | p2 | workflow/gate-execution | PENDING |
| #407 | (skills): Test-skills.sh leaks its whole temp tree per run, until the disk fills and assertions fail spuriously | KEEP | p2 | workflow/test-reliability | PENDING |
| #422 | (skills): Nothing stops a skill's Markdown accumulating an unshipped program — audit is clean today, add the guard | KEEP | p2 | workflow/skill-authoring | PENDING |
| #435 | (wrap): Sweep what a long session leaves behind — stale branches, cycle state, deferred notes, recordless claims | KEEP | p2 | workflow/session-cleanup | PENDING |
| #437 | (claim): Read the rigor:* label and announce the resolved caps — the rung is documented but unread | KEEP | p2 | workflow/policy-resolution | PENDING |
| #462 | (dev-flow): Dev loop: pre-flight the closing-keywords guard locally | KEEP | p2 | workflow/pr-metadata | PENDING |
| #470 | (claim): Recompute the preflight block whenever the accepted scope changes | KEEP | p2 | workflow/preflight | PENDING |
| #475 | (claim): Retain the gh scope evidence status:creds establishes | KEEP | p2 | workflow/preflight | PENDING |
| #492 | (kickoff): Distinguish planning-time claim labels from live claims | KEEP | p2 | workflow/claims | PENDING |
| #504 | (skills): Test tooling: emit progress during long skill test runs | KEEP | p2 | workflow/test-reliability | PENDING |
| #509 | (dev-flow): Codex connector: remove the draft-promotion failure class | KEEP | p2 | workflow/reviewer-authorization | PENDING |
| #514 | (test): Pin fixture environments in the flaky offline test suites | KEEP | p2 | workflow/test-reliability | PENDING |
| #515 | (dev-flow): Guard offline fixtures against live taxonomy value drift | KEEP | p2 | workflow/test-reliability | PENDING |
| #517 | (dev-flow): Dev loop: resume yielded gate sessions instead of | KEEP | p2 | workflow/gate-execution | PENDING |
| #527 | (docs): Document the git check-ref-format --branch shorthand-expansion gotcha in worktree/validation guidance | KEEP | p2 | workflow/branch-validation | PENDING |
| #529 | (dev-flow): Make background gate runs survive the periodic SIGTERM kills | KEEP | p2 | workflow/gate-execution | PENDING |
| #554 | (breakdown): Filter disabled native issue types | KEEP | p2 | workflow/issue-authoring | PENDING |
| #555 | (wrap): Distinguish merged PR commits from unpushed work | KEEP | p2 | workflow/session-cleanup | PENDING |
| #572 | (claim): Retry the record re-read before exiting 6 on comment lag | KEEP | p2 | workflow/claim-transactions | PENDING |
| #575 | (skills): make pasted shell snippets zsh-safe or run them under bash -c | KEEP | p2 | workflow/shell-portability | PENDING |
| #580 | (claim): Make the record template and helper agree on model-label n/a | KEEP | p2 | workflow/claim-transactions | PENDING |
| #584 | (claim): Tolerate a trailing newline in the published claim record | KEEP | p2 | workflow/claim-transactions | PENDING |
| #605 | (skills): Decide whether third-party skills (e.g. Matt Pocock's) get their own skill category | CLOSE-done | p3 | workflow/skill-authoring | PENDING |
| #610 | (session flow): Reconcile Herdr delegates at kickoff and wrap | KEEP | p2 | workflow/herdr-supervision | PENDING |
| #618 | (session workflow): Integrate Herdr supervision into the dev loop | KEEP | p1 | workflow/herdr-supervision | PENDING |
| #630 | (dev-flow): Replace prompt-sized policy with executable stages | KEEP | p1 | workflow/gate-execution | PENDING |
| #642 | (claim): Surface cross-repo publication blockers before review | KEEP | p1 | workflow/cross-repo-preflight | PENDING |
| #652 | (claim-lifecycle): Document the merged-PR event release path | KEEP | p2 | workflow/claims | PENDING |
| #653 | (skills): Document Herdr orchestration gotchas in the herdr skill | KEEP | p2 | workflow/herdr-supervision | PENDING |
| #654 | (claude): Record the exact model id when a dispatch asks for a pinned generation | KEEP | p2 | dispatch | PENDING |
| #659 | (wrap): Keep the claim across planned multi-slice deliveries | KEEP | p2 | claim-lifecycle | PENDING |
| #662 | (track-work): Reject escaped backtick pseudo-code spans | KEEP | p2 | issue-authoring | PENDING |
| #672 | (claim): Provide an autonomous-mode path for the claim writes | KEEP | p2 | claim-lifecycle | PENDING |
| #676 | (verify): Take test:shepherd-codex off the verify critical path | KEEP | p2 | gate-performance | PENDING |
| #692 | (tests): Cover implement and shepherd on-demand task ci wording | KEEP | p2 | gate-guidance | PENDING |
| #697 | (skills): Carry the gauntlet watcher prohibitions into implement | KEEP | p2 | gate-guidance | PENDING |
| #703 | (dev-flow): Close the P2 completeness residuals from the v2 spec PRs | KEEP | p2 | spec-completeness | PENDING |
| #712 | (session-flow): Record a timestamp in kickoff, claim, and implement so wall-clock time per stage can be computed | KEEP | p2 | run-observability | PENDING |
| #736 | (exit-fixtures): assert exit status in cross-validation checks | KEEP | p2 | test-integrity | PENDING |
| #746 | (wrap): Close safely-removable worktrees and herdr panes/tabs at session end | KEEP | p2 | session-cleanup | PENDING |
| #802 | (skills): Add a /learn skill that turns a correction into a dev-loop change (memory, artifact, or .devflow.toml setting) | KEEP | p3 | workflow-learning | PENDING |
| #813 | (dev-flow): Make the split-option blocker report trustworthy to render | KEEP | p1 | rendering-integrity | PENDING |
| #815 | (skills): add an implementer profile for the Antigravity CLI | KEEP | p2 | dispatch | PENDING |
| #816 | (skills): ship the orchestrator's agent-status watcher and stall detector as a skill asset | KEEP | p2 | supervision | PENDING |
| #817 | (claim): make the claim step's write non-optional in the implement flow | KEEP | p2 | claim-lifecycle | PENDING |
| #854 | (dev-flow): Consider a prompt-registry JSON that declares and validates per-harness, per-role prompts | KEEP | p3 | dispatch | PENDING |
| #870 | (retro): Enumerate session PRs and sweep claim markers with one script | KEEP | p2 | retro-live-sweep | PENDING |
| #877 | (dev-flow runtime): runtime manifest, atomic skills-sync install, offline verification, and /orchestrate preflight — residue after #974 | KEEP | p2 | runtime-distribution | PENDING |
| #880 | (skills): Document the sandboxed-Codex gate hand-off in the orchestrator brief template | KEEP | p1 | dispatch | PENDING |
| #882 | (dev-flow): Add Claude Code artifacts (HTML reports) to the dev flow | KEEP | p3 | run-observability | PENDING |
| #887 | (workflow): Clarify verification for docs-only corrections | KEEP | p2 | gate-performance | PENDING |
| #899 | (skills): Update orchestrator/review skill docs from kickoff-pinned to governing revision | KEEP | p2 | policy-docs | PENDING |
| #902 | (docs): Update stale references to removed breadth-vs-finder validation | KEEP | p2 | policy-docs | PENDING |
| #921 | (dev-flow): Rename the plan-approved strategy to say who approves (plan-ask, plan-gated, plan-then-approve) | NEEDS-DECISION | p3 | workflow-naming | PENDING |
| #922 | (dev-flow): Decide whether to rename the council strategy to market | NEEDS-DECISION | p3 | workflow-naming | PENDING |
| #938 | (scripts): P2 follow-up — env shebang quoting, seq portability, and bwrap fallback test coverage | KEEP | p2 | review-portability | PENDING |
| #978 | (ci): Create a skill to create decision records | NEEDS-DECISION | p3 | workflow-learning | PENDING |
| #979 | (skills): Create skill and prompt for nightly docs sync routine | KEEP | p3 | workflow-learning | PENDING |
| #986 | (retro): tighten discovery token boundaries and evaluate every same-tier body token before selecting | KEEP | p2 | retro-reconstruction | PENDING |
| #990 | (retro): a PR-only evidence marker with no local record is invisible to the targeted --run invocation | KEEP | p2 | retro-reconstruction | PENDING |
| #994 | (retro): Evidence-only and integrity output should carry discovery anomalies, the as-of cutoff, and verification gaps | KEEP | p2 | retro-reconstruction | PENDING |
| #1010 | (agent UX): Report human interventions as workflow failures | KEEP | p2 | run-observability | PENDING |
| #1011 | (copier): Format AI responses with templates, tables, outlines and emoji so prose is easier to scan | KEEP | p3 | output-design | PENDING |
| #1012 | (ci): Consider adding the built-in Claude Code simplify skill to the dev workflow after implement | NEEDS-DECISION | p3 | workflow-learning | PENDING |
| #1020 | (tasks): lint:markdown scans git-excluded files, so a lane report in the worktree fails task verify | KEEP | p2 | gate-performance | PENDING |
| #1021 | (tasks): add a quick per-round gate between check and verify for code rounds | KEEP | p2 | gate-performance | PENDING |
| #1022 | (retro): re-verify historical run records with their recorded rounds policy, not the live .devflow.toml caps | KEEP | p2 | retro-reconstruction | PENDING |
| #1029 | (retro): a run whose only marker was edited after the --as-of cutoff reports not-found instead of indeterminate | KEEP | p2 | retro-reconstruction | PENDING |
| #1046 | consider outputting and saving a report as part of the retro skill. Perhaps as a way to make orchestration runs more visible and observible and measurable and improvable. In contrast to issues, milestones, prs, etc orchestration sessions should have some kind of artifact to track and measure and improve. Similar general method to the groom skill report. | KEEP | p2 | run-observability | PENDING |
| #1058 | (retro): Finish the retro reconstruction follow-ups deferred from PR #991 and #962 | KEEP | p2 | retro-reconstruction | PENDING |
| #1068 | (verify): serialise task verify across parallel lanes and add a changed-scope gate | KEEP | p2 | gate-performance | PENDING |
| #1097 | (docs): the Codex guide says a cap of 0 never waives the current-head clean signal, contradicting AGENTS.md | KEEP | p2 | policy-docs | PENDING |
| #1099 | (dev-flow): mechanical guard that fails task verify when a vendored skill or agent invokes a repository-root scripts/ path | KEEP | p2 | runtime-distribution | PENDING |
| #1104 | docs(orchestrate): document OBSERVATION-DEGRADED and retire the restart-loop guidance in SKILL.md | KEEP | p2 | supervision | PENDING |
| #1105 | fix(orchestrate): poll an armed post-promotion window even while PR discovery is backing off | KEEP | p2 | supervision | PENDING |
| #1106 | test(orchestrate): cover lane-watch's round-2 fixes, skip gates, and the re-promotion 10/11 branch | KEEP | p2 | supervision | PENDING |
| #1107 | fix(orchestrate): harden lane-watch against an invalid retry timestamp and same-second id-less malformed rows | KEEP | p2 | supervision | PENDING |
| #1110 | (dev-flow): Establish a clean gate baseline before a session starts work | KEEP | p2 | gate-performance | PENDING |
| #1113 | fix(dev-flow-support): cover every closure reader layout in the fixtures and refuse symlinked candidates | KEEP | p1 | runtime-trust | PENDING |
| #1114 | test(skills): make the AC-5 vendored sweep hermetic and decide how vendored suites get their fixture corpus | NEEDS-DECISION | p2 | runtime-distribution | PENDING |
| #1118 | (dev-flow): Evaluate JEV for risk-based review scrutiny | KEEP | p2 | risk-based-scrutiny | PENDING |
| #1119 | (dev-flow): Generate all status views from one run record | KEEP | p2 | run-observability | PENDING |
| #1120 | (dev-flow): Reconcile acceptance scope before implementation | KEEP | p2 | acceptance-contract | PENDING |
| #1134 | (dev-flow): render-dev-flow bounds integration adjudication rounds by the Codex-cycle cap although integration_round counts integrator passes | CLOSE-done | p1 | dev-flow/cycle-accounting | PENDING |
| #1136 | fix(test): GNU-only date -d breaks test-integrate-codex.sh on macOS | KEEP | p1 | tests/portability | PENDING |
| #1154 | fix(dev-flow): carry the exempt ceiling through the orchestrated cap contracts | KEEP | p2 | dev-flow/policy-contract | PENDING |
| #1155 | test(integrate): test-integrate-codex.sh exited 2 once under load | KEEP | p2 | tests/determinism | PENDING |
| #1158 | (dev-flow): one policy.json contract for the run record, read identically by the readiness gate renderer and the retro harvester | KEEP | p2 | dev-flow/policy-contract | PENDING |
| #1171 | schema: the codex-cloud mirror in finder_cycles[] may contradict codex_cycle | NEEDS-DECISION | p2 | dev-flow/result-contract | PENDING |
| #1185 | (groom): Pass issue numbers as strings and parse with tonumber in write_outcome | KEEP | p3 | groom/reliability | PENDING |
| #1186 | (skills): Resolve skill asset directories with pwd -P as dev-flow-support documents | KEEP | p2 | skills/path-resolution | PENDING |
| #1188 | (groom): Grant checkout Read and one Bash path form in audit mode | KEEP | p2 | groom/permissions | PENDING |
| #1194 | (claim): Re-read post-publication state over a bounded settle window before reporting indeterminate | KEEP | p2 | claim/reconciliation | PENDING |
| #1207 | (dev-loop): Run the claim, tick, and integrate helpers behind a REST-only GitHub proxy | KEEP | p1 | dev-loop/remote-proxy | PENDING |
| #1214 | (dev-loop): Decide whether a delegate lane may run a default-branch catch-up merge | NEEDS-DECISION | p2 | orchestrate/authority | PENDING |
| #1232 | (claim): Refuse to claim an issue with an open blocked-by edge | KEEP | p2 | claim/preconditions | PENDING |
| #1236 | (tests): Make test-integrate-codex pass inside a nested .worktrees checkout | KEEP | p1 | tests/isolation | PENDING |
| #1258 | (glossary): define slate, slate plan, wave and lane — the dev-flow terms plan.json depends on | KEEP | p2 | docs/domain-vocabulary | PENDING |
| #1289 | (dev-flow): Project an optional [review_guidelines] table from .devflow.toml in the policy reader | KEEP | p2 | dev-flow/policy-configuration | PENDING |
| #1292 | (dev-flow): Apply per-stage empty-round floors from .devflow.toml in the reader, exit engine and readiness gate | KEEP | p2 | dev-flow/policy-configuration | PENDING |
| #1350 | (breakdown): Assert fallback rating families never carry Priority (AI) or suggest labels | KEEP | p3 | breakdown/test-coverage | PENDING |
| #1357 | (dev-flow): Leave a v2 run record from every Dev Loop session that /integrate and /retro can use | KEEP | p1 | dev-flow/universal-records | PENDING |
| #1369 | feat(dev-flow): persist per-round exit verdicts so split adjudications can be bound to their candidate | KEEP | p2 | dev-flow/verdict-persistence | PENDING |
| #1375 | fix(dev-flow-support): harden split chronology and issue-pattern anchoring after #1373 | KEEP | p2 | dev-flow/chronology | PENDING |
| #1382 | (retro): render dev-flow-stats adjudication overrides in the retro report and drop the #753-pending notes | KEEP | p2 | retro/measurements | PENDING |
| #1399 | (retro): fail closed on numeric finder-identity collisions per the registry schema | KEEP | p1 | retro/trust | PENDING |
| #1404 | feat(dev-flow): evaluate remediation pushes in one chronological pass to make the fixing ceiling airtight | KEEP | p2 | dev-flow/remediation-model | PENDING |
| #1418 | (validate): validate a bare integrator payload for runs without a record | KEEP | p2 | dev-flow/result-contract | PENDING |
| #1430 | fix(integrate): make the with-push path resilient to finder refusal and CI settling mid-review | KEEP | p2 | integrate/review-timing | PENDING |
| #1443 | fix(integrate): harden the CI-failed exempt charge (superseded cycles, fork and external CI, run selection, gate snapshot) | KEEP | p2 | integrate/cycle-accounting | PENDING |
| #1454 | (retro): reject aliased and malformed retained change ledgers before trusting provenance | KEEP | p1 | retro/provenance | PENDING |
| #1466 | (dev-flow): Reject six malformed result and run-record shapes the validator still accepts | KEEP | p1 | dev-flow/schema-integrity | PENDING |
| #1475 | (claim): Retry the post-publication liveness read and let an exact re-run resume | CLOSE-dup-of-#1194 | p2 | claim/reconciliation | PENDING |
| #1476 | (retro): Run the report from a current checkout and print the commit it ran at | KEEP | p2 | retro/evidence-freshness | PENDING |
| #1497 | (skills): Close five gaps in the raw gh api read lint left by #1338 | KEEP | p2 | skills/lint-coverage | PENDING |
| #1549 | (breakdown): Expand category-style surfaces into concrete file and producer inventories | KEEP | p2 | breakdown/scope-inventory | PENDING |
| #1550 | (dev-flow): Support a lower integration-cycle cap for documentation-only changes | KEEP | p2 | dev-flow/policy-configuration | PENDING |
| #1554 | (retro tests): fail test-dev-flow-stats when its fixture heredoc writes to stderr | KEEP | p2 | retro/test-reliability | PENDING |
| #1565 | fix(review): make round-push's docs_only_paths glob segment-aware like the CI classifier | KEEP | p2 | review/downstream-adoption | PENDING |
| #1570 | (retro): report unmeasured remediation and rejected-pass gaps honestly in older and edge-case records | KEEP | p2 | retro/measurements | PENDING |
| #1594 | (specs): State derive-on-read and the rigor-profile refinements in the dev-flow v2 tier paragraphs | KEEP | p3 | docs/tier-resolution | PENDING |
| #1595 | needs-review: orchestrate exclusion for issues it doesn't own, and pull-back order | KEEP | p2 | dev-loop/label-lifecycle | PENDING |
| #1601 | (dev-flow): Define the PR lifecycle states, the handoff check and the merge queue as one model | KEEP | p1 | dev-loop/lifecycle-model | PENDING |
| #1624 | fix(dev-flow-support): bind recorded policy projections to their run in lane-init and solo-init | KEEP | p1 | dev-flow/policy-trust | PENDING |
| #1627 | feat(orchestrate): watch promoted and parked PRs until merge instead of a fixed window | KEEP | p1 | orchestrate/pr-lifetime | PENDING |
| #1628 | feat(orchestrate): state the one-head merge queue, ready-claim re-check and flake policy | KEEP | p2 | orchestrate/merge-queue | PENDING |
| #1640 | fix(dev-flow-support): tighten plan merge-queue checks across revisions, cap counting and pr binding | KEEP | p2 | dev-flow/plan-integrity | PENDING |
| #1644 | (skills): Normalize groom audit run-directory bindings | KEEP | p2 | groom/path-bindings | PENDING |
| #1655 | docs(orchestrate): finish the sentinel vocabulary in test labels and lane-brief prose | KEEP | p3 | docs/sentinel-vocabulary | PENDING |
| #1681 | fix(dev-flow-support): check a pass's producer tier against the registry instead of trusting the envelope | KEEP | p1 | dev-flow/producer-trust | PENDING |
| #1696 | (skills): Make the process-ending convention prove ownership and fail closed wherever it is cited | KEEP | p1 | skills/process-authority | PENDING |
| #1702 | (dev-loop): Hold label-write conformance to an invariant instead of a growing regex list | KEEP | p2 | dev-loop/label-lifecycle | PENDING |
| #1705 | (tests): Make test-integrate-codex and test-inline-record deterministic under host load | KEEP | p1 | tests/determinism | PENDING |
| #1710 | fix(skills): settle the needs-review follow-ups deferred from #1709 | KEEP | p2 | dev-loop/label-lifecycle | PENDING |
| #1715 | (HUMAN): Complete manual setup for Orchestrator resilience | KEEP | p2 | orchestrate/human-setup | PENDING |
| #1717 | (skills): Run git reads, scripts and interpreters as their own Bash commands, not inside bash -c wrappers | KEEP | p2 | skills/command-shapes | PENDING |
| #1718 | (retro): test-retro-run-report's ENOENT race cases fail on macOS, where descriptor containment is refused | KEEP | p1 | tests/portability | PENDING |
| #1729 | (integrate): Document the missing-asset-path freshness cause deferred from #1727 | KEEP | p3 | policy-docs | PENDING |
| #1731 | lane-watch: degrade window spans bounded-pass gaps; terminal-exit rule too broad | KEEP | p2 | supervision | PENDING |
