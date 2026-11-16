# Label lifecycle

This is the canonical transition table for the [PR lifecycle ADR](../decisions/2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md)
and [fleet runs](../decisions/2026-10-26-fleet-standardization-runs.md).
The [glossary](../glossary.md) defines the terms; this page owns label events,
writers, object scope and coexistence. All label names are lowercase.

## Transition table

| Label | Adding event | Removing event | Writer skill | GitHub object | Never coexists with | Asset |
|---|---|---|---|---|---|---|
| `claim:*` (`claim:<harness>` in the ADR) | A verified claim starts, draft publication mirrors the active claim onto the newly opened draft PR, or real work resumes on a draft (including pre-handoff integration fix rounds). The actual vocabulary is `claim:<family>[:<model>]`, resolved from the host identity. | The delivery PR passes the handoff check (released **before** promotion: whether remaining parked or moving to queue-head promotion); terminal close or abandonment releases the remaining claim record and assignee. | `/claim` starts or resumes (mirroring active claim labels onto open draft same-repo delivery PRs and verifying both by re-reading; at draft publication, `/orchestrate` runs `plan-revise.mjs bind-pr` then idempotent `lifecycle-labels.sh claim --pr <P>`, which takes `claim-transaction.sh`'s exact-record resume path without recording a new claim); **release runs before promote**: orchestrated runs release via `plan-revise.mjs handoff` (after verifying current passing handoff-check gate evidence), and standalone/solo runs release via `lifecycle-labels.sh park` (then `promote.sh` promotes and removes `parked`), while `close` releases at terminal close — `plan-revise.mjs handoff` and `lifecycle-labels.sh` (`park`, `close`) share the canonical `{repo, issue, branch}` idempotency key and release both the issue and open (or `--pr`-named) same-repo delivery PRs through `track-work/assets/release-claim.sh` (`lifecycle-labels.sh promote` refuses while `claim:*` or `needs-review` remains); `/track-work` owns terminal release. | Issue and open draft same-repo delivery PR(s) if present | `parked`, `merge-ready` | `track-work/assets/lifecycle-labels.sh` (`add`: `claim`, `resume`, `fix-round` via `claim/assets/claim-transaction.sh`; `remove`: `park`, `close` via `track-work/assets/release-claim.sh`) |
| `slated` | An issue enters an orchestrator plan revision; a comment names the session and slate. | The issue leaves the plan, the slate closes, or the issue closes. | `/orchestrate` | Issue only | None; membership is independent of state and ownership. | `dev-flow-support/assets/plan-revise.mjs` (outside `lifecycle-labels.sh`) |
| `parked` | A non-head delivery PR passes the handoff check and waits in the merge queue as a draft. | It reaches the queue head and is re-checked for promotion, leaves the queue, resumes work, or closes. | `/orchestrate` | Both issue and delivery PR | `claim:*`, `merge-ready`, `needs-review`, `blocked` | `track-work/assets/lifecycle-labels.sh` (`add`: `park`; `remove`: `promote`, `unpark`, `resume`, `close`) |
| `merge-ready` | The queue head passes the live handoff check and is promoted; reapply only after a new live check passes. | Any late review, red required CI or base move invalidates readiness; also remove on return to draft or terminal close. | `/orchestrate` | Both issue and delivery PR | `claim:*`, `parked`, `needs-review`, `blocked` | `track-work/assets/lifecycle-labels.sh` (`add`: `promote`; `remove`: `unpromote`, `resume`, `close`) |
| `needs-review` | An agent owes review triggers, responses, fixes or adjudications on the delivery PR, whether draft or promoted: `/integrate` §2 applies it to issue and PR on review entry or renewed review, after removing `merge-ready`/`parked` from each object when present. | `/integrate` §6 clears the delivery PR and eligible issue before any readiness-gate check or promotion, then re-checks the implementer record; approved `/claim` pull-back and `/integrate` fix-round pull-back clear through `clear-needs-review.sh`; `/track-work` clears on issue close or delivery PR end. Human review or merge alone never retains it. | `/integrate` §2 and §6; `/claim` via the paired helper after establishing the live claim; `/track-work` paired helper for terminal cleanup | Issue and delivery PR; the issue marker is retained while another discoverable open same-repository delivery still carries `needs-review`. | `parked`, `merge-ready` on the same object | `track-work/assets/lifecycle-labels.sh` (`add`: `review-entry`; `remove`: `review-clear`, `fix-round`, `close`) |
| `blocked` | Progress requires a human decision or input, named in a comment; the delivery PR stays draft. | The named blocker is resolved, work is abandoned, or the issue or delivery PR closes. | `/orchestrate` | Issue and delivery PR when one exists | `parked`, `merge-ready` | `track-work/assets/lifecycle-labels.sh` (`add`: `block`; `remove`: `unblock`, `close`) |

**Working is not a label.** Working is the issue's `claim:*` marker (mirrored
on open draft same-repo delivery PRs — at draft publication via `plan-revise.mjs
bind-pr` followed by idempotent `lifecycle-labels.sh claim --pr <P>`), not a
second `working` label. Working lanes count toward `max_parallel_agents`, and a
draft PR retains both its active claim and Working slot until passing handoff
check.
The **in-flight set** is issues carrying `claim:*` **or an open delivery PR**,
counted once per issue toward `max_in_flight`, including parked and promoted
PRs. `slated` marks slate membership only: it is not a state, not ownership,
and counts toward no ceiling. It alone does not exclude an issue from the
Agent queue; `/claim` reports slate membership without treating it as a claim
conflict. An open delivery PR independently excludes an issue from that queue.

A passed parked draft or queue head stays orchestrator-owned until merge or
close. Catch-up and re-check upkeep do not re-add a claim. Actual resumed work
returns a promoted PR to draft before reclaiming. Base movement removes
`merge-ready` during the live check; the PR may remain promoted unless its new
head owes review. These are the ADR's transitions, not new states.

## Executable write inventory

`/claim` applies ownership, never a lifecycle state label. The only claim
machinery is `claim/assets/claim-transaction.sh`,
`claim/assets/resolve-claim-label.sh` (read-only plan resolver), and
`track-work/assets/release-claim.sh`. The claim machinery adds claim labels and releases them on close.
`/integrate` releases the chain-owned claim labels at handoff-check pass
**before** promotion — orchestrated runs through `plan-revise.mjs handoff`
and standalone/solo runs through `track-work/assets/lifecycle-labels.sh park`
(shared through `track-work/assets/release-claim.sh` under the `{repo, issue,
branch}` idempotency key), releasing the issue claim together with its delivery
PR mirrors and re-reading both rather than invoking raw `gh issue edit
--remove-label` writes; after release (or `park`), `promote.sh` promotes and
its `lifecycle-labels.sh promote` event removes `parked` and applies
`merge-ready` (`lifecycle-labels.sh promote` never releases `claim:*` and
refuses if any `claim:*` or `needs-review` label remains); reconciling the
remaining `#1988` multi-branch PR scope is tracked in
[#1988](https://github.com/evanharmon1/harmon-devkit/issues/1988). A missing or unreadable record leaves labels
untouched; already-absent labels are skipped and successful writes are verified
by re-reading the issue. Release removes only proven
chain-owned labels; restoration of a displaced claim follows the parsed record.
Legacy `agent:*` aliases remain supported by that same machinery.

The table below inventories **existing executable sites**, not permission to
add new lifecycle transitions. Paths are relative to `ai/skills/universal/`;
operands are literal source expressions. Dynamic claim operands must be resolved and
validated by the named machinery. Filing labels are caller-supplied metadata
validated by the issue-metadata preflight, not additional lifecycle authority.
`needs-triage` is filing metadata, not a lifecycle state.

| Asset | Operation | Source operand | Label vocabulary |
|---|---|---|---|
| `claim/assets/claim-transaction.sh` | `--add-label` | `"$claim_label"` | `claim:*`, `agent:*` |
| `claim/assets/claim-transaction.sh` | `--add-label` | `"$model_label"` | `claim:*` |
| `dev-flow-support/assets/plan-revise.mjs` | `--add-label` | `slated` | `slated` (2 sites) |
| `dev-flow-support/assets/plan-revise.mjs` | `--remove-label` | `slated` | `slated` |
| `track-work/assets/release-claim.sh` | `--remove-label` | `"$l"` | `claim:*`, `agent:*` |
| `track-work/assets/release-claim.sh` | `--add-label` | `"$restore_displaced"` | `claim:*`, `agent:*` |
| `track-work/assets/clear-needs-review.sh` | `--remove-label` | `"$label"` | `needs-review` |
| `track-work/assets/lifecycle-labels.sh` | `--add-label` | `"$add_label"` | `parked`, `merge-ready`, `needs-review`, `blocked` |
| `track-work/assets/lifecycle-labels.sh` | `--remove-label` | `"$remove_label"` | `parked`, `merge-ready`, `needs-review`, `blocked` |
| `track-work/assets/file-review-finding.sh` | `--label` | `"$label"` | Caller-supplied lowercase filing metadata (validated by the issue-metadata preflight). |
| `track-work/assets/file-review-finding.sh` | `--label` | `needs-triage` | `needs-triage` |
| `track-work/assets/file-review-finding.sh` | `--add-label` | `needs-triage` | `needs-triage` |

There are currently no executable label writes in orchestrate or integrate
assets, and no REST label mutation calls in these four asset trees. The
conformance test enumerates the trees rather than trusting that absence.
Event-causing callers delegate through `track-work/assets/lifecycle-labels.sh`:

- `integrate/assets/drive-codex-cycle.sh` invokes `lifecycle-labels.sh review-entry` when posting a `@codex review` trigger.
- `integrate/assets/promote.sh` rehearses `lifecycle-labels.sh promote --check` before `gh pr ready` (refusing while `claim:*` or `needs-review` remains on the issue or any delivery PR), verifies a fresh `readiness-gate.sh promoted` pass after recording promotion and applies `lifecycle-labels.sh promote` (removing `parked` and adding `merge-ready`), and invokes `lifecycle-labels.sh unpromote` when `readiness-gate.sh check` fails on red CI, late review, or `merge-ready-behind`.
- `integrate/assets/update-branch.sh` invokes `lifecycle-labels.sh unpromote` on a promoted PR before sending the update-branch request (refusing before any mutation if the issue cannot be resolved or `unpromote` fails).
- `claim/assets/claim-transaction.sh --approve-review-pullback` invokes `lifecycle-labels.sh fix-round` when open delivery PRs exist (and delegates to `clear-needs-review.sh` for zero-PR/nested calls).

The non-write preflight helper `metadata+=(--label "$label")` in
`track-work/assets/file-review-finding.sh` is inventoried separately from the
`create+=(--label "$label")` write. Each inventory row accounts for one site
unless its count is stated.

### Paired review-marker wiring

`needs-review` means an agent still owes review work on the delivery PR (review triggers, responses, fixes, adjudications).
The helper's inventoried `gh "$kind" edit` write serves both `issue` and `pr`;
it verifies selected PRs before clearing the issue. The claim transaction
has no separate issue-only review-label write: its approved pull-back delegates
with the recorded branch to the same helper:

```sh
"$cleanup_dir/clear-needs-review.sh" --repo "$repo" --issue "$issue" --branch "$recorded_branch"
```

- **Pull-back into fix rounds:** the live claim takes over. `/integrate` clears
  `needs-review` from both objects and restores the exact chain-owned claim
  labels independently. An operator-approved `/claim` pull-back passes
  `--approve-review-pullback` to `claim-transaction.sh`, which otherwise enforces
  the review hold. After committing the claim, it calls paired cleanup and
  verifies the live claim; a failure is non-zero. Retry the same committed record AND
  `--approve-review-pullback` to finish partial cleanup without republishing the
  claim; a resume without that flag refuses a live review hold. Approval waives
  no other blocker. Verify cleanup and the exact chain-owned claim restores
  before resuming fixes; when review becomes due again, use `/integrate` §2.
  If pull-back cleanup prints `NEEDS-REVIEW-RETAINED`, treat it as a failure, report it on stderr, leave the PR draft and do not resume fixes, as `/claim` does.

- **Issue close or delivery PR end:** clear discoverable markers independently
  of claim trust. PR-end callers supply the PR number, including for drafts
  closed unmerged and merged `Refs` deliveries. Issue-close callers need the
  claim branch to discover an open `Refs` delivery without a closing link.

`track-work/assets/clear-needs-review.sh --repo OWNER/NAME --issue N [--pr N] [--branch BRANCH]`
owns removal independently of claim trust. Discoverable means closing-linked,
or an open same-repository PR on the given `--branch`. The transaction passes
the recorded claim branch to the helper; the helper owns discovery and marker
verification. With an explicit/event PR, clear only that PR.
The issue marker is retained only while a discoverable open same-repository delivery PR still carries needs-review.
A Refs PR on another branch is not discoverable.

Exit 0 means the selected PRs are clear; if the issue marker is retained, stdout
contains the stable line `NEEDS-REVIEW-RETAINED`. No such line means the issue
marker was cleared or absent. Read/write or verification failures are non-zero.
Existing harmon-init PR-end callers supply `PR_NUMBER` and matching `GH_REPO`,
preserving their argv. Issue-close callers with only `--repo`/`--issue` discover
closing links only; they must supply the claim branch for an open Refs delivery.
Until the template-owned caller supplies that branch, issue close clears the
issue marker but leaves an open, unlinked Refs PR marker in place. Cleanup
reaches that PR when it closes unmerged. On merge, cleanup skips already-closed
issues and can leave the PR marker in place. The issue-close caller change is
tracked in [harmon-init#1897](https://github.com/evanharmon1/harmon-init/issues/1897).
The helper reads all discoverable objects before writing and verifies removals.
GitHub offers no transaction across label writes; retry partial cleanup before
reporting success. The event wiring is template-owned; the claim-release event table in `track-work/references/claim-lifecycle.md`
describes claim release separately.

Terminal event wiring remains template-owned:
[harmon-init#1778](https://github.com/evanharmon1/harmon-init/issues/1778).

## Adoption and verification

`parked` and `merge-ready` provisioning belongs to
[harmon-init#1787](https://github.com/evanharmon1/harmon-init/issues/1787);
`slated` provisioning and wiring belong to
[harmon-init#1845](https://github.com/evanharmon1/harmon-init/issues/1845) and
[#1688](https://github.com/evanharmon1/harmon-devkit/issues/1688). A table row
does not provision a label or grant a missing executable capability. Missing
provisioning or paired-write support must be reported rather than silently
substituted with a different transition.

Run `task test:label-lifecycle` to compare every label mutation site in claim,
orchestrate, integrate and track-work assets to this inventory. Unknown writes,
unknown dynamic operands, uppercase label vocabulary and REST label mutations
without an inventory entry fail. Mutation probes verify the refusals. This is
static conformance; the lifecycle implementation issues still own live GitHub
transition tests.

### Lifecycle label audit

`track-work/assets/label-lifecycle-audit.mjs --repo OWNER/NAME [--slate SLATE]`
is a read-only audit of open slated or claimed issues and their delivery PRs.
It reads `never-coexist` pairs and mirrored/managed state labels from
`track-work/assets/lifecycle-labels.sh --rules-json`, reports violations as a
JSON array naming `{repo, object, labels, class}` (exiting non-zero when any
violation exists), and writes nothing to GitHub. Repairing reported violations
remains a transition through `lifecycle-labels.sh` or a human decision.

### Retained lanes and Working capacity

Handoff releases the lane's Working slot and removes its `claim:*`, while its
session, tab, panes, worktree and branch remain idle. A parked or blocked lane's
pane or tab may close only where the repository's own `AGENTS.md` permits it at
a passing handoff (`orchestrate` § Orchestrator autonomy contract); where
`AGENTS.md` still requires the session to stay alive, it stays. Closing a pane
retains the worktree and branch. An open delivery PR still
counts toward `max_in_flight`. Every code-change round returns to the existing
session, after admission under `max_parallel_agents`; a held open-PR fix takes
the next free Working slot before a new dispatch. The claim returns for that
round, and another passing handoff check releases the slot again. Only lane
teardown after merge removes its worktree. Closing a PR
without merging still needs maintainer approval for teardown. A fresh run
record does not require a fresh session; replace a session only if it is gone.
