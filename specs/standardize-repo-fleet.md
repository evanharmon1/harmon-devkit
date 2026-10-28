# Spec: Standardize-repo fleet runs

- **Status:** Draft
- **Owner:** Evan Harmon
- **Date:** 2026-10-26
- **Related:** [ADR 2026-10-26 fleet standardization runs](../docs/decisions/2026-10-26-fleet-standardization-runs.md), [#1657](https://github.com/evanharmon1/harmon-devkit/issues/1657), [#1658](https://github.com/evanharmon1/harmon-devkit/issues/1658), [#1659](https://github.com/evanharmon1/harmon-devkit/issues/1659), [harmon-infra#882](https://github.com/harmonops/harmon-infra/issues/882), [ADR 2026-10-23 PR lifecycle](../docs/decisions/2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md)

## Problem / Why

Applying a harmon-init release to the fleet is thirteen manual skill runs
with about fifty maintainer stops, no inventory, no wave order, no record of
rulings, no reconciliation of GitHub-side configuration, and reviews that
judge template content the repository did not write. The maintainer wants one
invocation that asks a fixed set of questions, then runs the fleet in waves
with up to five lanes and reports on issues.

## Goal

`/standardize-repo` with no arguments performs a fleet run: reads the
inventory and decisions from harmonops/harmon-infra, asks the start-of-run
questions once, creates the fleet epic and per-repo tracking issues, hands the
slate to `/orchestrate` under the `standardize-repo` run profile, probes and
reconciles each repository's GitHub-side configuration, scopes every review
to the application of the template, and leaves a fleet report on the epic, a
per-repo report on each tracking issue, and human-only work in the epic's
`(HUMAN):` collector.

## Non-goals

- Merging, releasing, or rebuilding devcontainers inside a run.
- Dependency updates beyond the toolchain floors the release requires
  (Renovate owns them; harmon-init#1345 carries the improvements and any
  separate dependency session).
- Replacing each repository's scheduled skills-sync PR.
- Targeting harmon-init, harmon-ops (deprecated), `test-project` or
  `test-wind` (relics).
- Writing secrets, installing Apps, or changing plan features.

## Requirements

### Inputs and home

- [ ] `fleet/inventory.yaml` in harmonops/harmon-infra lists every managed
      repository with owner, project type, wave, template commit, skills pin,
      and exclusions with reasons; a JSON Schema and `task validate:fleet`
      guard it; the runner-routing audited-repos list reads from it.
- [ ] `fleet/decisions.yaml` holds per-release rulings keyed by release:
      pre-approved reconcile classes, per-repo answer changes, review
      exclusions, model rulings, legacy-baseline and rollback approvals.
- [ ] The skill reads both through a configurable fleet repository (default
      harmonops/harmon-infra) and fails with the path it needs when either is
      unreadable; nothing under `ai/skills/` names a private repository.

### Start-of-run questions

- [ ] `SKILL.md` lists the ordered question set with each question's default,
      its decisions-file key, and the later stop it removes.
- [ ] An asset renders the questions from the inventory and decisions file,
      records answers under the release, and presents each repository's
      carried-forward answers with the release's new questions once, from the
      parent.
- [ ] A lane that lacks a ruling stops naming the key; it never asks and never
      self-confirms.
- [ ] The question set includes the disposition of open skills-sync PRs for
      the whole run, merge-first or absorb, decided once and never per lane.

### Units and orchestration

- [ ] A run creates, idempotently by marker, one fleet epic in harmon-infra
      and one tracking issue per target repository as its sub-issues, each
      following the track-work authoring contract.
- [ ] `/orchestrate` accepts an issue with sub-issues as the slate and plans
      issues from several repositories, provisioning each lane in its
      repository's clone while slate state stays under the conductor's git
      common dir.
- [ ] Waves follow the inventory's owner order; a wave releases when every
      issue of the previous wave is done, parked or merge-ready; a
      `blocked_by` edge still waits for the merge.
- [ ] `.devflow.toml` carries `max_in_flight` on every breadth profile, a
      `[breadth.fleet]` profile, and a `[run.standardize-repo]` profile; the
      policy reader resolves and announces them; the plan validator bounds
      working lanes (issues carrying `claim:*`) by `max_parallel_agents` and
      in-flight issues (`claim:*` or an open delivery PR) by `max_in_flight`.
- [ ] One transition table beside the glossary names, for `claim:<harness>`,
      `slated`, `parked`, `merge-ready`, `needs-review` and `blocked`, the
      event that adds the label, the event that removes it, and the skill
      that owes the write; `/claim`, `/orchestrate` and `/integrate` link to
      it, and a conformance test holds each skill's label writes to it.
- [ ] `slated` is provisioned in the label registry (harmon-init#1845), applied by the
      orchestrator with a comment naming the session and slate when an issue
      enters a plan revision, removed when the issue leaves the plan, the
      slate closes or the issue closes, counted toward no ceiling, and
      reported but never treated as a conflict by `/claim`.
- [ ] Lanes run `/claim`, the guarded update, and `/integrate` unchanged,
      with a fleet section in the lane brief: release, inventory row,
      decisions keys, review scope, report obligations.

### Guarded update

- [ ] The §1b–§2c guarded update ships as one asset with `prepare`,
      `discover`, `present`, `apply`, `reconcile`, `promote` and `rollback`
      subcommands and tests; `mode-update.md` becomes a runbook that calls it.
- [ ] Every variable derivable from `.copier-answers.yml` is derived, never
      requested.
- [ ] The pre-flight reads the release's minimum skills pin, bumps the pin
      in the same PR only when the repository is below it, reports pin lag
      per repository in the reconcile table, and handles an open sync PR
      under the run's one ruling (merge-first or absorb).
- [ ] The update PR carries the toolchain floors the release requires (pnpm
      major, Node, copier, task, the devcontainer tool pins) and no other
      dependency change.

### GitHub-side reconcile

- [ ] One machine-readable classified item list, shipped by harmon-init and
      read by the skill, gives every checklist item a probe, a write action or
      none, and a class: agent-apply, agent-apply with fleet approval,
      human-only verified empirically, unknown.
- [ ] `task audit:github` runs the probes and prints one JSON row per item;
      a probe without permission reports unknown; secrets are probed by name
      only.
- [ ] Lanes run probes and write report rows; only the parent runs writes,
      serialized per owner, per repository once its default branch is proven
      at the selected release (the lane's PR merged, or the guarded update
      produced no change and the lane proved `_commit` equals the release on
      a clean tree, with no PR opened and the tracking issue recording no
      change), limited to the classes the decisions file pre-approved, and
      re-probes to prove each write; a repository whose PR is closed unmerged
      or stays blocked keeps its rows pending and holds no other repository's
      writes.
- [ ] `task setup:github` runs in every mode and sets
      `delete_branch_on_merge: true`, `allow_update_branch: true`,
      `allow_auto_merge: false`.
- [ ] `task setup:ruleset` writes the template ruleset for the repository's
      profile additively; `task audit:ruleset` is run per repository and its
      drift is a report row; a repository with custom check names conforms,
      and no override exists.
- [ ] A Renovate-health row reports the Dependency Dashboard issue and the
      rendered `renovate.json` against the template render.
- [ ] A standing per-repo configuration status issue, found by marker and
      rewritten by `task audit:github -- --issue`, is the durable state;
      `docs/CHECKLIST.md` becomes a static index of items that cannot be
      probed.
- [ ] Human-only gaps are appended to the fleet epic's `(HUMAN):` collector
      through track-work, grouped per owner, with the probe that proved them
      and a source line on the tracking issue.
- [ ] A fleet run begins by checking the orchestrator's own container
      against the staleness probe and the release's tool floors, and stops
      with the rebuild command before any lane starts when the check fails.
- [ ] The devcontainer row reports definition rendered, `devcontainer-verify`
      on the head and whether the ruleset requires it, the devcontainer-build
      run on the default branch for the merged head (succeeded and pushed),
      and the staleness probe; the fleet report lists the rebuild queue with
      one command per workspace, ordered after a wave's merges; a run never
      rebuilds a container.

### Review scoping

- [ ] `scripts/lib/review-instructions/standardize.txt` exists and the local
      review scripts select it with `--profile standardize`, excluding only
      files identical in content and git mode to the previous release's
      frozen render at the merge base and to the new release's frozen render
      on the head; a file the repository had customized stays in scope;
      `.copier-answers.yml`, conflict resolutions and repo-owned files are
      never excluded; and when the exclusion would empty the scope the review
      runs on the full diff under the same profile.
- [ ] The PR body's `## Review scope` section and the PR reviewers' scope are
      rendered from one source; the canonical review guidelines carrier
      (harmon-init#1529) offers a `standardize` profile.
- [ ] A template-content finding is filed upstream by default, and the
      adjudication record says so; the default decides where the fix lands,
      never the severity: a confirmed P0 or P1 affecting the target repository
      still blocks the lane and is fixed with a repo-local override, avoided
      by a release choice, or escalated.

### Reports

- [ ] The fleet epic body carries one row per repository: PR, head, lifecycle
      state, silent non-adoption count, skills pin state, reconcile summary,
      post-merge metadata status.
- [ ] Each tracking issue body carries the per-repo report: answers changed,
      PR and head, state, non-adoption list, reconcile rows with probe result,
      action and class, devcontainer row.
- [ ] Both are rewritten in place by marker, byte-identical when unchanged,
      refused when the marker is missing, at each lane transition and after
      the parent's writes.

## Acceptance criteria (Given / When / Then)

### Scenario: bare invocation runs the fleet

- **Given** the inventory lists fourteen repositories in three waves and the
  decisions file has no entry for v5.13.1
- **When** the maintainer invokes `/standardize-repo` and answers the
  question set with defaults
- **Then** the decisions file gains a v5.13.1 entry, one fleet epic and
  fourteen tracking sub-issues exist, and `/orchestrate` starts wave 1 with
  at most five Working lanes

### Scenario: a wave releases on handoff-check pass

- **Given** wave 1 has three tracking issues and all three PRs are parked or
  merge-ready while none is merged
- **When** the orchestrator recomputes the queue
- **Then** wave 2 lanes start, the in-flight count stays at or below
  `max_in_flight`, and the plan revision records the release reason

### Scenario: a lane never writes GitHub-side configuration

- **Given** a lane's probe finds `delete_branch_on_merge` off
- **When** the lane reaches its reconcile step
- **Then** it writes a report row with class agent-apply and action pending,
  and makes no API write

### Scenario: the parent reconciles each repository after its merge

- **Given** two of wave 1's three PRs have merged, the third is blocked, and
  the decisions file pre-approves agent-apply and fleet-approved classes
- **When** the parent runs the reconcile writes for owner evanharmon1
- **Then** `task setup:github` and `task setup:ruleset` run once for each
  merged repository, in series, each re-probed; the blocked repository's rows
  stay pending; and the per-repo status issues and fleet report show the new
  probe results

### Scenario: a repository already at the release still reconciles

- **Given** a repository's `_commit` already equals the selected release and
  the guarded update produces no change, while its probe shows
  `delete_branch_on_merge` off
- **When** the lane finishes
- **Then** no PR is opened, the tracking issue records no change, and the
  parent runs the pre-approved writes for that repository once the lane has
  proved the release on a clean default branch

### Scenario: exclusions never empty the review

- **Given** an update whose every changed file is pristine on both sides
- **When** `task challenge -- --profile standardize` computes the exclusion
  list
- **Then** the review runs on the full diff under the standardize profile
  and the runner never receives an empty scope

### Scenario: a lost customization stays in review

- **Given** a repository had customized `lefthook.yml` (or only its
  executable bit on a template script) and the update replaced it with the
  template's render
- **When** `task review -- --profile standardize` computes the exclusion list
- **Then** `lefthook.yml` is in scope because it differed from the previous
  release's frozen render at the merge base

### Scenario: a blocking template defect does not clear by filing

- **Given** a reviewer confirms a P1 in template-rendered CI configuration
  that breaks the target repository's deploy
- **When** the lane adjudicates the finding
- **Then** it is filed upstream and the lane still owes a repo-local
  override, a release choice, or an escalation before the gate can pass

### Scenario: a human-only gap reaches the collector once

- **Given** two repositories under one owner lack the CI App installation
- **When** their lanes report the probe result
- **Then** the fleet epic's `(HUMAN):` collector holds one item for that
  owner naming both repositories and the probe, and each tracking issue has a
  source line

### Scenario: reviewers see the application, not the template

- **Given** a standardize PR whose diff is 90 percent frozen-render-identical
  files
- **When** `task challenge -- --profile standardize` runs and the PR reviewers
  read their configuration
- **Then** the local review scope excludes the identical files, the
  instructions name the release and the adjudication default, and a
  template-content finding is recorded as filed upstream

### Scenario: a lane lacks a ruling

- **Given** a repository's update introduces a new copier question with no
  decisions-file entry
- **When** the lane reaches `confirm-answers.sh`
- **Then** the lane stops with the key it needs and the parent, not the lane,
  records the answer

### Scenario: a stale orchestrator container stops the run first

- **Given** the orchestrator's container fails the staleness probe or lacks
  a tool floor the selected release requires
- **When** `/standardize-repo` is invoked
- **Then** the run stops before creating the epic or starting any lane, and
  reports the rebuild command for that workspace

### Scenario: a pin below the minimum is bumped in the same PR

- **Given** a repository's skills pin is below the release's minimum and
  another repository's pin is above it but behind the latest skills release
- **When** their lanes run the guarded update
- **Then** the first PR bumps the pin to the minimum alongside the template
  update, the second PR leaves the pin alone, and the reconcile table shows
  the lag for both

### Scenario: a slated issue is visible before its lane starts

- **Given** the slate's plan revision lists a wave-3 tracking issue that no
  lane has claimed
- **When** another session runs `/claim` on that issue
- **Then** the issue carries `slated` with a comment naming the fleet
  session and slate, `/claim` reports the membership and proceeds, and no
  ceiling counted the issue as in flight

### Scenario: re-invocation is idempotent

- **Given** a run for v5.13.1 already created the epic and tracking issues
- **When** `/standardize-repo` is invoked again for v5.13.1
- **Then** the existing epic and issues are found by marker and reused, and
  no duplicate is created

## Open questions

- Cross-organization sub-issues: a user-owned parent with children in both
  organizations is proven (harmon-init#1345 holds harmonops and ponderousdev
  children; #1657 holds harmon-infra children). An organization-owned epic
  in harmonops with a ponderousdev child is the untested case; the first
  run attaches one and, if GitHub refuses, the epic body carries the tracked
  list and the per-repo reports link back to it.

## Resolved questions

- Reviewer scope lives only in the PR body's `## Review scope` section and
  the canonical guidelines carrier (harmon-init#1529). A branch-local change
  to a reviewer's configuration is not allowed: the branch would be choosing
  how it is reviewed, the same self-modification the merge-base rule for
  `.devflow.toml` forbids, and the template re-renders the file anyway.
- harmon-infra's custom required-check names conform to the template
  (harmon-infra#884); there is no override path.
- Human-only gaps go to the fleet epic's `(HUMAN):` collector only, grouped
  per owner, with a source line on each tracking issue. A second copy on a
  per-repo collector would drift from the first, and the track-work scope
  ladder already routes to the epic.

## Notes

Rollout: implement the devflow and orchestrate changes first (issues 1660
through 1664 in harmon-devkit), then the skill assets, then pilot on wave 1
(the maintainer's own repositories) for one release before running all three waves. The template
tasks (harmon-init milestone "Fleet standardization support") can land
independently and are useful per repository without the skill.
