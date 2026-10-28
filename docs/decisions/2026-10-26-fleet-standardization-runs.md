# Fleet standardization runs

Date: 2026-10-26

## Status

Accepted (2026-10-28) — maintainer approval recorded in the milestone 6
orchestration session once the first implementation PRs had merged
(#1700, #1708, #1701).

## Context

Applying a harmon-init release to the managed fleet is the most repeated
multi-repo operation in harmon-platform. The 2026-10 rollout of v5.7.2 to
v5.8.2 reached thirteen repositories through thirteen separate
`standardize-repo` runs. The maintainer stopped about fifty times, mostly to
answer the same questions per repository, to confirm the same copier answers,
and to hand each lane its review. Nothing recorded which repositories were
targets, what was decided, or what was left undone; the retro filed
[#1537](https://github.com/evanharmon1/harmon-devkit/issues/1537),
[#1535](https://github.com/evanharmon1/harmon-devkit/issues/1535),
[#1533](https://github.com/evanharmon1/harmon-devkit/issues/1533),
[#1531](https://github.com/evanharmon1/harmon-devkit/issues/1531) and
[harmon-init#1734](https://github.com/evanharmon1/harmon-init/issues/1734).

A fleet audit on 2026-10-26 (fourteen managed repositories across
evanharmon1, harmonops, sommerlawn and ponderousdev) found the GitHub-side
half of standardization in the same state: `delete_branch_on_merge` off
everywhere, no main ruleset on five repositories, seven rulesets missing the
template's `closing-keywords` and `devcontainer-verify` contexts, one
repository requiring its own check names, Dependabot alerts off on one. Each
repository's `docs/CHECKLIST.md` is re-rendered by every copier update, so its
ticks are never state: ponderous-site shows 65 unticked and 0 ticked items
although labels, project and CI App were set up in the last rollout.

Four constraints shape the design:

- `ai/skills/` ships from a public repository into every generated repository.
  A list of private repositories and per-release rulings cannot live there.
- `/orchestrate` plans one repository at a time from a milestone or an issue
  list, keys lanes by issue, provisions lanes from one clone, and releases a
  dependent only after its blocker merges. The 2026-10-23 PR-lifecycle ADR
  already retires a lane when its PR passes the handoff check.
- `.devflow.toml` is the place where orchestration and agent behaviour are
  expressed, by default and ahead of time; a run that needs five lanes must be
  expressible there rather than in a skill's private cap.
- A standardize PR is mostly upstream template content. Reviewers that judge
  it as the repository's own code produce template findings the repository
  cannot act on (ponderousdev/lawnomator-site#255).

## Decision

### The fleet's home is harmonops/harmon-infra

The managed-repo inventory (`fleet/inventory.yaml`: owner, repository, project
type, wave, template commit, skills pin, exclusions with reasons) and the
fleet decisions file (`fleet/decisions.yaml`: per-release rulings) live in
harmonops/harmon-infra. It is private, it already holds fleet-level GitHub
operations (runner-routing reconcile with its audited-repos lists, the App
manifest, issue-field setup), and its existing audited-repos list becomes a
view of the same inventory. Per-run fleet epics, their reports and their
`(HUMAN):` collectors live there too, and harmon-infra vendors the `repo` skill
category so a fleet run launches from its checkout. The answers themselves are
not secret: the only `_secret_questions` are `password` and `key`, and no
managed repository's answers hold an email, token or account id. What is
private is the inventory.

harmon-ops is deprecated and never a target. `test-project` and `test-wind`
are v2 relics and never targets. harmon-init is the template and never a
target.

### One run is one epic, one tracking issue per repository, one slate

A run for release vX creates, idempotently by marker, one fleet epic in
harmon-infra (`(fleet): Standardize to harmon-init vX`, labelled `epic`) and
one tracking issue per target repository in that repository
(`(standardize): Apply harmon-init vX`), attached as the epic's sub-issues.
The tracking issues are the slate; `/orchestrate` claims, implements and
integrates them with the ordinary stage skills, so every lane follows the
unchanged `/claim`, `/implement` and `/integrate` contracts and the maintainer
merges each PR exactly as any other. Orchestrate learns two things to make
this possible: an epic or umbrella issue as the slate input, and a repository
per plan issue with a lane provisioned in that repository's clone while slate
state stays under the conductor's git common dir.

### Waves release on handoff-check pass, under two ceilings

Waves follow the owner order the maintainer set: evanharmon1; harmonops and
sommerlawn; ponderousdev. A wave boundary is a preference, not a code
dependency, so the next wave starts when every PR of the previous wave has
passed the handoff check (parked or merge-ready), not when it merges. A
`blocked_by` edge still waits for the merge. Capacity is expressed in
`.devflow.toml`: `max_parallel_agents` bounds working lanes, and a new
`max_in_flight` bounds issues in flight at once, so a lane whose PR waits on
the maintainer does not hold a working slot. A `[breadth.fleet]` profile (5
parallel, 15 in flight) and a `[run.standardize-repo]` profile that names
rigor, breadth and strategy together make the fleet run selectable by name.
The skill carries no lane cap of its own.

The states are the 2026-10-23 PR-lifecycle ADR's, shown by its lowercase
labels and by no new state label. Working is the issue's `claim:<harness>`
label, applied by `/claim` and released by `/integrate` when the PR passes
the handoff check; the claim machinery already decides when that label goes
on and comes off, so no `working` label mirrors it. `parked`, `merge-ready`,
`needs-review` and `blocked` are applied and removed by the orchestrator and
the integration stage at the transitions that ADR names. An issue is in
flight when it carries `claim:*` or has an open delivery PR, whatever labels
that PR carries. One transition table, kept beside the glossary, states for
every label the event that adds it, the event that removes it, and the skill
that owes the write; the skills link to the table rather than restating it,
and a conformance test holds each skill's writes to it.

One label is added, `slated`, for slate membership rather than state. The
orchestrator applies it, with a comment naming the session and the slate,
when an issue enters a plan revision, and removes it when the issue leaves
the plan, the slate closes, or the issue closes. It counts toward no ceiling
and is not an ownership marker: `/claim` reports another session's `slated`
and continues, and `claim:*` stays the only ownership signal.

### The questions are asked once

A fixed, ordered question set opens every run: target release, scope, per-repo
copier answer changes presented as carried-forward answers plus the release's
new questions, which agent-apply reconcile classes may run, legacy-baseline
acceptance, guarded-rollback approval, model rulings for lanes, and review
exclusions. The answers are written to the decisions file under the release
and lanes read them. A lane that lacks a ruling stops naming the key it needs;
it never asks the maintainer and never decides for them.

### GitHub-side configuration is reconciled, probes in lanes and writes from the parent

Every mode ends with a reconcile phase that works from one classified item
list the template and the skill share. Each item carries a read-only probe, a
write action or none, and a class: agent-apply (idempotent and reversible,
already scripted: `task setup:github` including repo settings,
`task setup:github-labels` in additive mode, `task setup:github-project`,
issue fields and types, non-secret Actions variables); agent-apply with fleet
approval (consequential writes pre-approved per release: `task setup:ruleset`,
label force-reconcile); human-only, verified empirically (secrets by name, App
installations by a succeeded token-minting run, Renovate by its dashboard
issue, Codex and CodeRabbit toggles, plan features); and unknown, when the
probe lacks permission. Lanes run the probes and write report rows. Only the
parent runs writes, serialized per owner, per repository once its default
branch is proven at the selected release: the lane's PR merged, or the
guarded update produced no change and the lane proved `_commit` equals the
release on a clean tree, in which case no PR is opened and the tracking
issue records no change. The parent re-probes to prove each write. A
repository whose PR is closed unmerged or stays blocked keeps its rows at
pending and never holds the others' writes back. `task setup:github` runs in every mode. `delete_branch_on_merge`
is on by default (harmon-init#411's ruling, implemented through the same
task). Required status checks per project type come from the template's
ruleset render, and a repository with custom check names conforms
(harmon-infra#884 renames its `build-verify`, `security-verify` and
`validate-verify` aggregates to the template's `verify` and `security`); the
decisions file carries no check-name override, because an override would be
re-reported by every audit and would exempt the one repository the template
cannot keep green. The classified list also carries a Renovate-health row
(the Dependency Dashboard issue present, the rendered `renovate.json` at the
template's) and the toolchain floors the release requires (pnpm major, Node,
copier, task, the devcontainer tool pins), because the template dictates
both.

State lives in a standing per-repo configuration status issue written from
probe results and in the run's reports, never in the re-rendered checklist,
which becomes a static index of the items that cannot be probed. Human-only
gaps go to the fleet epic's `(HUMAN):` collector through track-work's
collector procedure, grouped per owner, with the source line on the tracking
issue.

### Reviews judge the application, not the template

Local `task challenge` and `task review`, the PR body's `## Review scope`
section, and each PR reviewer's configuration receive the same scope from one
rendered source: judge whether harmon-init vX was applied appropriately to
this repository (customizations preserved, conflicts and `.rej` files
resolved, answers right for this repository, intentional divergences not
resurrected, renames handled, repo-only tasks and workflows still wired, pins
coherent, stack- and deployment-specific corner cases), and treat template
content as given. A file is excluded from the local review diff only when it
was pristine on both sides: identical in content and git mode to the previous
release's frozen render at the merge base and to the new release's frozen
render on the head. A file the repository had customized stays in scope even
when the update leaves it identical to the template, because that equality is
exactly how a lost customization looks. The exclusion is an aid, never a gate:
`.copier-answers.yml`, conflict resolutions and repo-owned files are never
excluded, and when the exclusion would empty the scope the review runs on the
full diff under the same profile, so an update whose every changed file is
pristine on both sides still gets its application reviewed rather than an
empty scope that the runner rightly refuses. A finding about template content is filed upstream
by default; that default decides where the fix lands, not the finding's
severity. A confirmed P0 or P1 that affects the target repository still
blocks the lane under the ordinary gate: it is fixed with a repo-local
override, avoided by a release choice, or escalated, and filed upstream as
well.

### Reports live on the issues

The fleet epic body carries the fleet report and each tracking issue carries
its per-repo report, rewritten in place by marker with the triage report's
mechanism (whole-body rewrite, byte-identical when unchanged, refusal when the
marker is missing). The inventory is the cross-run state; there is no rolling
dashboard issue.

### Deterministic steps are scripts that compose with template tasks

Anything a lane repeats thirteen times per release and that can be decided
mechanically ships as an asset with tests: the guarded update as one asset
with `prepare`, `discover`, `present`, `apply`, `reconcile`, `promote` and
`rollback`; the question set; the slate builder; the report renderer. Per-repo
GitHub work composes with the template's Taskfile targets, so a repository
can run its own reconcile without the skill, and the skill adds only the
fleet-level orchestration and reporting.

### What the run does not absorb

- **Skills sync** stays with each repository's scheduled sync PR. The run
  reads the release's minimum pin (harmon-init#1734, #1533) and bumps the
  pin in the same PR only when the repository is below it, the case the last
  rollout stalled on four times. An open sync PR is handled by one
  start-of-run ruling for the whole run, merge-first (the sync PR goes ahead
  of the standardize PR) or absorb (the standardize PR supersedes it), never
  per lane. The reconcile table reports pin lag per repository; the routine
  bump stays with the scheduled sync and Renovate.
- **Dependency updates** stay with Renovate, for scope rather than volume: a
  dependency bump inside a template-application PR makes the review scope
  impossible to state and dilutes what a reviewer judges, and dependencies
  have their own cadence, test risk and automation. Two exceptions belong in
  the run because the template dictates them: the toolchain floors the
  release requires, applied in the update PR, and the Renovate-health row in
  the reconcile report, which on 2026-10-26 found sommerlawn-zoho without a
  Dependency Dashboard issue, so Renovate is inert there. Everything else
  about dependency maintenance changes separately from this run under the
  dependency epic harmon-init#1345, which carries the endorsed improvements
  (a shared versioned preset, lockfile-aware grouping, holds with removal
  conditions, artifact retention, measurement before targets). A fleet-wide
  dependency merge run is not planned; if one is ever wanted it is its own
  slate after a wave, never part of standardize.
- **Devcontainers** are verified, never rebuilt. A fleet run starts by
  checking the orchestrator's own container against the staleness probe and
  the release's tool floors, because lanes in a stale container fail the new
  gates and look like template defects. Each lane confirms the devcontainer
  builds and `devcontainer-verify` are green on its head, and the reconcile
  report flags a repository whose ruleset does not require
  `devcontainer-verify` (seven did not on 2026-10-26). After each merge the
  parent probes that the devcontainer-build run on the default branch for the
  merged head succeeded and pushed, so the GHCR image matches the definition;
  it reads the workflow run and needs no packages scope. The fleet report
  ends with a rebuild queue: each workspace whose checkout moved past its
  image, with the one command that rebuilds it, ordered after a wave's
  merges. The template owns the root cause: image staleness in the
  SessionStart summary with a baked digest of the Dockerfile,
  `devcontainer.json` and Feature pins (harmon-init#1832), and a host-side
  `task devcontainer:rebuild` per profile (harmon-init#1833).
- No new `devcontainer-update` or `dependency-update` skill is created; those
  are template tasks and report rows.

### Alternatives rejected (the explicit "not")

- **Not a fleet file inside the skill:** `ai/skills/` is public and shipped;
  the inventory names private repositories.
- **Not a repo-keyed fleet plan outside orchestrate:** it would duplicate
  claim, implement and integrate; one tracking issue per repository reuses
  them unchanged.
- **Not a skill-private lane cap:** `.devflow.toml` exists to express
  orchestration ahead of time; the fleet profile goes there.
- **Not wave release on merge:** the maintainer's merge cadence would idle
  lanes; handoff-check pass is the lifecycle's own retirement point.
- **Not writes from lanes:** org-level and credential-adjacent calls stay with
  the parent, serialized per owner, so lane permissions stay narrow.
- **Not checkbox state in `docs/CHECKLIST.md`:** copier re-renders it; probe
  results are the only state that survives an update.
- **Not reviewing template content per repository:** template defects are
  filed upstream once.
- **Not rebuilding devcontainers or merging dependency PRs inside a run:**
  both widen the run's blast radius and blur its review scope.
- **Not a groom-style HTML report:** the maintainer works from issues, and the
  triage report already proves the marker-rewrite mechanism.
- **Not a `working` label:** `claim:<harness>` already is the working state,
  with its own transaction, resolver and release; a second label would drift
  from the claim it mirrors.
- **Not custom required-check names:** the template renders one ruleset per
  project type and the audit and setup tasks compare against it; a
  per-repository override is permanent drift that every run must carry.

## Consequences

A release rollout becomes one invocation, one epic, and as many merges as
there are repositories. The maintainer's stops are the start-of-run
questions, per-repo answer confirmations presented once, and merges. Every
repository's GitHub-side state is probed every run and recorded where an
update cannot erase it, and human-only work accumulates in one collector per
run. Orchestrate gains epic input, multi-repo slates and handoff-pass wave
release; `.devflow.toml` gains `max_in_flight`, a fleet breadth profile and
named run profiles. The template gains probe and write tasks and a classified
checklist that the skill reads rather than restates.

Implementation is tracked by the harmon-devkit milestone "Standardize-repo
fleet runs", the harmon-init milestone "Fleet standardization support" and
the harmon-infra milestone "Fleet standardization home", under three epics:

- [#1657](https://github.com/evanharmon1/harmon-devkit/issues/1657) the fleet
  run: questions, inventory-driven slate, waves and ceilings, orchestrate
  epic and multi-repo input, the label transition table (#1687) and
  `slated` (#1688), guarded-update asset, reports.
- [#1658](https://github.com/evanharmon1/harmon-devkit/issues/1658) the
  GitHub-side reconcile: classified items, `task audit:github`, status issue,
  `task setup:ruleset`, repo settings, additive labels, Renovate health and
  toolchain floors (#1689), devcontainer rows.
- [#1659](https://github.com/evanharmon1/harmon-devkit/issues/1659) review
  scoping and the skills-pin minimum.

Until those land, the skill keeps its four single-repo modes and this record
changes no behaviour. The spec is
[`specs/standardize-repo-fleet.md`](../../specs/standardize-repo-fleet.md).
