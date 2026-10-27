# Label lifecycle

This is the canonical transition table for the [PR lifecycle ADR](../decisions/2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md)
and [fleet runs](../decisions/2026-10-26-fleet-standardization-runs.md).
The [glossary](../glossary.md) defines the terms; this page owns label events,
writers, object scope and coexistence. All label names are lowercase.

## Transition table

| Label | Adding event | Removing event | Writer skill | GitHub object | Never coexists with |
|---|---|---|---|---|---|
| `claim:*` (`claim:<harness>` in the ADR) | A verified claim starts or real work resumes on a draft. The actual vocabulary is `claim:<family>[:<model>]`, resolved from the host identity. | The delivery PR passes the handoff check (whether parked or merge-ready); terminal close or abandonment releases the remaining claim record and assignee. | `/claim` starts or resumes; `/integrate` requests handoff release; `/track-work` owns terminal release. All claim-label mutations go through the claim machinery below. | Issue only | `parked`, `merge-ready` |
| `slated` | An issue enters an orchestrator plan revision; a comment names the session and slate. | The issue leaves the plan, the slate closes, or the issue closes. | `/orchestrate` | Issue only | None; membership is independent of state and ownership. |
| `parked` | A non-head delivery PR passes the handoff check and waits in the merge queue as a draft. | It reaches the queue head and is re-checked for promotion, leaves the queue, resumes work, or closes. | `/orchestrate` | Both issue and delivery PR | `claim:*`, `merge-ready`, `needs-review`, `blocked` |
| `merge-ready` | The queue head passes the live handoff check and is promoted; reapply only after a new live check passes. | Any late review, red required CI or base move invalidates readiness; also remove on return to draft or terminal close. | `/orchestrate` | Both issue and delivery PR | `claim:*`, `parked`, `needs-review`, `blocked` |
| `needs-review` | An agent owes review triggers, responses, fixes or adjudications on the delivery PR, whether draft or promoted. | No agent review work remains, even if human review or merge is still owed; terminal close also clears it. | `/integrate`; `/track-work` terminal cleanup | Both issue and delivery PR, applied and removed together | `parked`, `merge-ready` |
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
`track-work/assets/release-claim.sh`. Callers request these operations instead
of spelling out raw claim-label writes. Release removes only proven
chain-owned labels; restoration of a displaced claim follows the parsed record.
Legacy `agent:*` aliases remain supported by that same machinery.

The table below inventories **existing executable sites**, not permission to
add new lifecycle transitions. Paths are relative to `ai/skills/universal/`;
operands are literal source expressions. Dynamic operands must be resolved and
validated by the named machinery, never accepted as arbitrary label input.
`needs-triage` is filing metadata, not a lifecycle state.

| Asset | Operation | Source operand | Label vocabulary |
|---|---|---|---|
| `claim/assets/claim-transaction.sh` | `--add-label` | `"$claim_label"` | `claim:*`, `agent:*` |
| `claim/assets/claim-transaction.sh` | `--add-label` | `"$model_label"` | `claim:*` |
| `claim/assets/claim-transaction.sh` | `--remove-label` | `"$review_label"` | `needs-review` |
| `track-work/assets/release-claim.sh` | `--remove-label` | `"$l"` | `claim:*`, `agent:*` |
| `track-work/assets/release-claim.sh` | `--add-label` | `"$restore_displaced"` | `claim:*`, `agent:*` |
| `track-work/assets/clear-needs-review.sh` | `--remove-label` | `"$label"` | `needs-review` |
| `track-work/assets/file-review-finding.sh` | `--add-label` | `needs-triage` | `needs-triage` |

There are currently no executable label writes in orchestrate or integrate
assets, and no REST label mutation calls in these four asset trees. The
conformance test enumerates the trees rather than trusting that absence.

The claim transaction's approved review pull-back cleanup and the issue-only
`clear-needs-review.sh` are existing compatibility sites. They do not redefine
`needs-review` as human review, authorize state-label additions by `/claim`, or
satisfy the paired issue/PR lifecycle write on their own. Paired review-marker
wiring belongs to [#1608](https://github.com/evanharmon1/harmon-devkit/issues/1608);
terminal review-marker wiring belongs to
[harmon-init#1778](https://github.com/evanharmon1/harmon-init/issues/1778).
Keep these compatibility sites visible until that wiring replaces them.

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
