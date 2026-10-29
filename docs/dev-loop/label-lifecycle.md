# Label lifecycle

This is the canonical transition table for the [PR lifecycle ADR](../decisions/2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md)
and [fleet runs](../decisions/2026-10-26-fleet-standardization-runs.md).
The [glossary](../glossary.md) defines the terms; this page owns label events,
writers, object scope and coexistence. All label names are lowercase.

## Transition table

| Label | Adding event | Removing event | Writer skill | GitHub object | Never coexists with |
|---|---|---|---|---|---|
| `claim:*` (`claim:<harness>` in the ADR) | A verified claim starts or real work resumes on a draft. The actual vocabulary is `claim:<family>[:<model>]`, resolved from the host identity. | The delivery PR passes the handoff check (whether parked or merge-ready); terminal close or abandonment releases the remaining claim record and assignee. | `/claim` starts or resumes; `/integrate` removes each exact chain-owned base and model label named by the claim record at handoff-check pass; `/track-work` owns terminal release. Claim machinery adds the labels and releases them on close; handoff label-only release follows the recorded ownership below. | Issue only | `parked`, `merge-ready` |
| `slated` | An issue enters an orchestrator plan revision; a comment names the session and slate. | The issue leaves the plan, the slate closes, or the issue closes. | `/orchestrate` | Issue only | None; membership is independent of state and ownership. |
| `parked` | A non-head delivery PR passes the handoff check and waits in the merge queue as a draft. | It reaches the queue head and is re-checked for promotion, leaves the queue, resumes work, or closes. | `/orchestrate` | Both issue and delivery PR | `claim:*`, `merge-ready`, `needs-review`, `blocked` |
| `merge-ready` | The queue head passes the live handoff check and is promoted; reapply only after a new live check passes. | Any late review, red required CI or base move invalidates readiness; also remove on return to draft or terminal close. | `/orchestrate` | Both issue and delivery PR | `claim:*`, `parked`, `needs-review`, `blocked` |
| `needs-review` | An agent owes review triggers, responses, fixes or adjudications on the delivery PR, whether draft or promoted: `/integrate` §2 applies it to issue and PR on review entry or renewed review, after removing `merge-ready`/`parked` from each object when present. | `/integrate` §6 clears the delivery PR and eligible issue before any readiness-gate check or promotion, then re-checks the implementer record; approved `/claim` pull-back and `/integrate` fix-round pull-back clear through `clear-needs-review.sh`; `/track-work` clears on issue close or delivery PR end. Human review or merge alone never retains it. | `/integrate` §2 and §6; `/claim` via the paired helper after establishing the live claim; `/track-work` paired helper for terminal cleanup | Issue and delivery PR; the issue marker is retained while another discoverable open same-repository delivery still carries `needs-review`. | `parked`, `merge-ready` on the same object |
| `blocked` | Progress requires a human decision or input, named in a comment; the delivery PR stays draft. | The named blocker is resolved, work is abandoned, or the issue or delivery PR closes. | `/orchestrate` | Issue and delivery PR when one exists | `parked`, `merge-ready` |

**Working is not a label.** Working is the issue's `claim:*` marker, not a
second `working` label. Working lanes count toward `max_parallel_agents`.
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
`track-work/assets/release-claim.sh`. Callers request these operations for claims and terminal release.
`/integrate` performs label-only release at handoff-check pass using each exact
base and model label named by the claim record; it leaves the assignee and record
live and posts no release comment. A missing or unreadable record leaves labels
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
| `track-work/assets/release-claim.sh` | `--remove-label` | `"$l"` | `claim:*`, `agent:*` |
| `track-work/assets/release-claim.sh` | `--add-label` | `"$restore_displaced"` | `claim:*`, `agent:*` |
| `track-work/assets/clear-needs-review.sh` | `--remove-label` | `"$label"` | `needs-review` |
| `track-work/assets/file-review-finding.sh` | `--label` | `"$label"` | Caller-supplied lowercase filing metadata (validated by the issue-metadata preflight). |
| `track-work/assets/file-review-finding.sh` | `--label` | `needs-triage` | `needs-triage` |
| `track-work/assets/file-review-finding.sh` | `--add-label` | `needs-triage` | `needs-triage` |

There are currently no executable label writes in orchestrate or integrate
assets, and no REST label mutation calls in these four asset trees. The
conformance test enumerates the trees rather than trusting that absence.

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
