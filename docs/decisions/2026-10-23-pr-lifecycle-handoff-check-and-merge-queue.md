# PR lifecycle, handoff check and merge queue

Date: 2026-10-23

## Status

Accepted

## Context

The maintainer settled this model during ponderousdev/omator's milestone 19
orchestration on 2026-10-22/23. PRs were reported ready while behind the base,
with red CI or an unanswered CodeRabbit review. A review arrived 40 minutes
after promotion, beyond the fixed 15-minute watch window.

The conflict inventory in [#1601](https://github.com/evanharmon1/harmon-devkit/issues/1601)
found eight disagreements in the existing policy and implementation:

1. “Ready”, “handoff” and “done” each named several different events or states.
2. Late reviews caused withdrawal in orchestrate, drift-only reporting in
   integrate, and no observation after the watch window.
3. Currency was required at promotion but not maintained afterwards; the
   post-window read did not check whether the PR was behind.
4. Readiness had different condition counts, and some prose used the unreliable
   `mergeStateStatus` cache to decide currency.
5. Prose gated only on Codex; the gate covered driven finders rather than every
   required reviewer, leaving other review products outside the contract.
6. CI meant required checks, every check, or every reported check in different
   places.
7. Thread resolution was required in one place and reserved to the maintainer
   without gating in another.
8. `needs-review` meant out of the agent queue; no labels distinguished a passed
   PR waiting its turn from the PR the maintainer should merge now.

## Decision

### GitHub facts and agent states

GitHub states are facts: **Draft** is open with `isDraft = true`;
**Promoted** is open with `isDraft = false`. Agents may promote only out of a
passing handoff check and retain the right to demote. **Merged** and **Closed**
are always human acts.

Agent states are shown with labels; the Working claim label is on the issue,
and `needs-review` is on both the issue and its delivery PR, applied and removed
together with the same agent-owed meaning:

| State | GitHub | Label | Meaning |
|---|---|---|---|
| Working | draft | `claim:<harness>` on the issue | An agent owes implementation, review rounds, fixes, CI or catch-up on a draft; orchestrator upkeep is excluded. |
| Needs review | draft or promoted | `needs-review` on both issue and delivery PR | An agent still owes review work on the delivery PR: review triggers, responses, fixes or adjudications. The label comes off when none remains, even if a human still has to look at or merge the PR; it never coexists with `merge-ready` or `parked`. |
| Parked | draft | `parked` | Passed the handoff check earlier and waits in the merge queue; deliberately not kept current. |
| Blocked | draft | `blocked` | Needs a human decision or input named in a comment. |
| Merge-ready | promoted | `merge-ready` | Queue head whose handoff check passes now; the maintainer is asked to merge it. |

`needs-review` means an agent still owes review work on the delivery PR (review
triggers, responses, fixes, adjudications). When the agent owes none of that,
the label comes off, even if a human still has to look at or merge the PR. A PR
waiting on a human is `merge-ready` or `parked`, never `needs-review`, and the
label never sits together with either. Apply and remove `needs-review` on both
the issue and its delivery PR together, with that same meaning on each.

**Handoff** is promoting out of a passing handoff check, then applying
`merge-ready`; it is an act, not another state. “Ready to merge” means the
handoff check passes now. Retire other uses of “ready”, “handoff” and “done”, or
rename them: the lane `HANDOFF-` sentinel becomes `DRAFT-PUBLISHED-`, the
`READY-` report becomes the merge-ready report, and the PR body section is
“Deferred findings”. The [glossary](../glossary.md) is the term lookup; skills
link there rather than restating the definitions.

### One live handoff check

One predicate is re-run live before promotion, before applying `merge-ready`,
and before any message telling the maintainer a PR is ready. An earlier result
is never reused:

1. **Current with the base:** live `compare/<base>...<head>` has
   `behind_by == 0`. Do not use `mergeStateStatus` for currency.
2. **Required CI green:** the latest run of each required check on the exact
   head concluded successfully. Skipped is neutral. Pending or missing is
   indeterminate. Report failing non-required checks to the maintainer; they
   do not block.
3. **Required reviews complete on this head:** every reviewer required for this
   PR by `.devflow.toml` was requested on this head or its verdict legitimately
   carries; it finished by its own completion signal, not a timer; and every
   finding is fixed, declined with evidence, or filed. There is no outstanding
   `CHANGES_REQUESTED` review on the PR (`reviewDecision != CHANGES_REQUESTED`).
4. **Every thread settled:** it has the agent's reply, and either the agent has
   the last word or the thread is resolved. A reviewer's acknowledgement
   followed by resolving the thread settles it.
5. **PR body and run record complete:** deferred findings ticked, disclosures
   present, closing keyword correct.
6. **Nothing moved:** re-read head and review activity immediately before the
   action or message.

### Ordered merge queue and continuing ownership

The orchestrator orders PRs that passed the handoff check to minimize conflicts,
catch-ups and re-reviews: file overlaps go first-to-merge, and small independent
units may go ahead. Only the head is promoted, kept current and labelled
`merge-ready`. Every other passed PR stays a draft labelled `parked`, is not
caught up, and is reported as parked. When the head merges, catch up the next
PR once, re-check it, promote it and apply `merge-ready`.

This supersedes the wording in
[#1591](https://github.com/evanharmon1/harmon-devkit/issues/1591) and
[harmon-init#1781](https://github.com/evanharmon1/harmon-init/issues/1781)
that promoted PRs further back stay behind the base: those PRs stay drafts.
[#1608](https://github.com/evanharmon1/harmon-devkit/issues/1608) replaces
[#1592](https://github.com/evanharmon1/harmon-devkit/issues/1592)’s handoff-time
`needs-review` marking together with an Agent-queue exclusion of issues that
have an open delivery PR. The predicate lands through harmon-init#1787 together
with that handoff change, so handed-off issues stay out of the Agent queue.

A lane retires when its PR passes the handoff check, whether parked or
merge-ready; release the issue’s `claim:<harness>` label at that point. The
orchestrator owns parked drafts, catches them up and re-checks them when they
reach the queue head. That parked-draft or queue-head upkeep is not Working and
does not re-add the claim. The orchestrator owns and watches every PR until it
merges or closes, for as long as it is open. There is no fixed 15-minute
post-promotion window: time passing cannot prove a review finished. Keep
[#969](https://github.com/evanharmon1/harmon-devkit/issues/969)'s rule to lead
every message with a withdrawal when one is owed.

Any change on a promoted PR — late review, red required CI or base movement —
removes merge-ready status; the orchestrator removes `merge-ready` and acts.
A late finding needing a code change sends the PR back to draft by default.
A finding declined or filed without a code change is settled in place. A base
move gets a catch-up as queue-head upkeep, not Working-state work: the PR
stays promoted, with `merge-ready` removed only while the handoff check re-runs.
Return to draft only if the new head owes a review. Work may restart on a PR
that was promoted: return it to draft first. The issue’s claim label returns
only when work resumes on a draft; orchestrator upkeep does not re-add it.
Working remains draft-only.

### Reviewer coverage and carry

Each reviewer is a finder in `.devflow.toml [stage.integration]`, with trigger
text, per-PR budget and covered rounds, completion signal, whether it gates,
and carry behaviour. Defaults are overridable per repository and per PR.
Per-PR overrides come only from an operator instruction recorded in the run;
no label family carries them for now. Template defaults:

| Reviewer | Budget and coverage |
|---|---|
| Codex | Existing rounds policy. |
| Claude | Up to 2, on the first two rounds. |
| Greptile | Up to 1, on the first round. |
| CodeRabbit | 1 full review on the first round, then up to 2 incremental. |
| Gemini | Added with a budget to be set. |

For every reviewer, a byte-identical PR diff, proved by the canonical diff
digest, owes nothing. An offsets-only move owes the next budgeted incremental
review where the reviewer has one, and nothing otherwise. A real change owes
a fresh round within each reviewer's budget.

### Flakes and check visibility

A failure in a file the PR does not touch may be re-run once; record the re-run.
On the second sighting, file and fix the flake rather than re-running again.
The bot reads check runs through a GitHub App installation token so the handoff
check can see them through the Checks API.

### Alternatives rejected (the explicit “not”)

- **Not a fixed 15-minute post-promotion window:** a late review can arrive
  after it closes; elapsed time does not prove reviewer completion.
- **Not `mergeStateStatus` for currency:** it is an unreliable cache; the live
  comparison's `behind_by` proves whether the head is current.
- **Not reusing an earlier handoff-check result:** base, head, CI or review
  activity may have changed; each action and readiness message needs live proof.
- **Not keeping non-head passed PRs promoted but behind:** only the queue head
  is kept current and offered for merge; waiting PRs remain parked drafts to
  avoid misleading readiness and repeated catch-ups and reviews.
- **Not withdrawing promotion by default for late findings settled without
  code:** declining with evidence or filing can settle them in place; draft
  withdrawal is the default when the finding needs a code change.

## Consequences

Promotion alone no longer tells the maintainer to merge: a live handoff check
and `merge-ready` do. Parked drafts avoid repeatedly catching up and reviewing
PRs that cannot merge yet. Watching continues until merge or close, and late
work can resume with explicit ownership. Neither a quiet timer, a cached merge
state, nor an earlier handoff result substitutes for live evidence.

This ADR records the accepted model; implementation is split across:

- [#1602](https://github.com/evanharmon1/harmon-devkit/issues/1602): integrate's
  handoff check, finder coverage, late findings to draft, thread settlement and
  required CI, including condition 3’s outstanding changes-requested block.
- [#1603](https://github.com/evanharmon1/harmon-devkit/issues/1603): orchestrate's
  queue and labels, watch until merge, removal of the fixed window, sentinel
  renames, ownership and flake policy, including queue-head catch-up upkeep
  and lane retirement after passing the handoff check.
- [#1604](https://github.com/evanharmon1/harmon-devkit/issues/1604): the
  `devflow-policy.mjs` reader, finder fields and per-repository then per-PR
  override resolution; it ships the reader only. Per-PR overrides
  come only from an operator instruction recorded in the run; no label family
  carries them for now.
- [#1608](https://github.com/evanharmon1/harmon-devkit/issues/1608): the
  `needs-review` add/remove wiring on both the issue and delivery PR for the
  agent-owed meaning, after #1604. It replaces #1592’s handoff-time marking
  together with the Agent-queue exclusion of issues with an open delivery PR;
  harmon-init#1787 carries the template predicate and docs.
- [#1605](https://github.com/evanharmon1/harmon-devkit/issues/1605): handoff check
  reads check runs through the GitHub App installation token.
- [harmon-init#1786](https://github.com/evanharmon1/harmon-init/issues/1786):
  `AGENTS.md` template and root twin implement the policy;
  [harmon-init#1795](https://github.com/evanharmon1/harmon-init/issues/1795)
  follows up to align the `AGENTS.md` twins and Codex review guide with the
  amendments.
- [harmon-init#1787](https://github.com/evanharmon1/harmon-init/issues/1787):
  `.devflow.toml.jinja` reviewer entries gated on Copier answers,
  `use_claude_review`, the `.devflow.schema.json` finder fields,
  `agent-registry.json` reviewer entries, and `label-registry.json` definitions
  of `parked`, `merge-ready` and `needs-review`.

Until those children land, existing skills and gates may still implement the
older contract. This documentation change does not modify their behaviour.
