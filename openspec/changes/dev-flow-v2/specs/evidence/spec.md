## Purpose

Defines durable, authenticated Dev flow run and round evidence from kickoff
through ready-for-review so failed runs, metrics, replay, and retrospectives do
not depend on a surviving branch or session memory.

## ADDED Requirements

### Requirement: Every kickoff reserves a durable run record

The actor kicking off a run SHALL create a unique run identity and reserve its
run-record comment on the issue before any branch or PR is required. The local
working copy SHALL live under the repository's common git directory keyed by
run ID, with a branch pointer to the active run, so linked worktrees share the
record and reused branch names do not reuse trajectories.

#### Scenario: A run dies before creating a branch

- **WHEN** kickoff was recorded but the environment disappears before PR creation
- **THEN** the issue retains a discoverable nonterminal run that can later be terminalized as abandoned

### Requirement: Role outputs and adjudications remain immutable

Raw role results and adjudication records SHALL be immutable after receipt.
Run history, including stage transitions, interventions, and terminal outcome,
SHALL live in append-only run-record entries rather than editable summary fields.
Deferred-finding terminal settlements SHALL likewise be append-only, keyed by
finding ID, and SHALL NOT rewrite the original evidence comment or adjudication
digest.

#### Scenario: Integration settles a deferred finding

- **WHEN** the orchestrator chooses fix, decline, or file for a deferred finding
- **THEN** one settlement is appended for that finding without editing its original adjudication

### Requirement: Every adjudicated round is posted promptly

After each confidence round is adjudicated, its validated evidence SHALL be
posted on the issue with a deterministic run, stage, round, and sequence marker.
At draft creation, the PR SHALL receive one stage projection linking the issue
rounds. A run that ends without a PR SHALL post the same stage evidence beside
its issue blocker record. PR creation SHALL NOT delete local evidence.

#### Scenario: Challenge caps before a PR exists

- **WHEN** the run stops with a gating finding at its challenge cap
- **THEN** the issue holds the run record, stage trajectory, and blocker needed for later replay

### Requirement: Evidence writes are reserve-first and idempotent

Before any GitHub evidence write, the system SHALL persist a deterministic
reservation locally. Before creating a comment, it SHALL search the destination
for that marker and adopt the lowest-ID matching comment authored by the run's
trusted actor instead of posting. An untrusted matching marker SHALL be reported
and SHALL NOT suppress the legitimate write. Because GitHub comment creation has
no idempotency key, concurrent writers can still double-post; the trusted
comment with the lowest ID is canonical, and every reader SHALL treat later
duplicates as superseded and ignore them. Harvesting SHALL resolve duplicate
markers by this rule rather than report them as ambiguous.

#### Scenario: Posting succeeds but the comment ID is not recorded

- **WHEN** interruption occurs after the trusted comment is created
- **THEN** a resumed writer adopts the existing comment by marker and records its ID without creating a duplicate

#### Scenario: Concurrent writers create duplicate markers

- **WHEN** two trusted comments are created with the same reservation marker
- **THEN** the lowest comment ID is canonical and every reader ignores the later duplicate as superseded

### Requirement: Evidence is scanned and safely redacted

Every free-text evidence projection SHALL pass the repository's secret scanner
before posting. If a secret span is detected, the public evidence SHALL replace
the span with a stable placeholder and scanner rule ID while retaining the
unredacted evidence only locally; the run SHALL remain durable without
disclosing the secret.

#### Scenario: Reviewer evidence quotes a credential

- **WHEN** the secret scanner identifies a credential in a finding's evidence
- **THEN** the posted projection contains a stable redaction and rule ID, never the credential value

### Requirement: Harvested evidence is authenticated

At kickoff, the orchestrator SHALL append a run-index entry containing
`run_id`, `initiated_by`, branch, and run-record digest where the claim lives on
the issue, and the branch pointer SHALL name that run. The run record SHALL
store evidence comment IDs, immutable author actor IDs, display logins,
canonical SHA-256 payload digests, and marker sequence. A harvester SHALL accept
only comments named by the trusted run record whose current author and body
match those values. The issue-level index and branch pointer, not the continued
existence of deletable evidence comments, SHALL anchor run discovery. If an
indexed run's evidence chain is missing or broken, the harvester SHALL reject it
as deleted-entry tampering, never reinterpret it as a run that did not happen.
The run-record author's authority SHALL derive from configured trusted
orchestrator actor IDs or the trusted kickoff event, never an identity declared
inside the record. The digest chain defends against non-trusted actors and
accidental edits; a compromised trusted-account token is explicitly out of
scope because it defeats every mechanism in the repository, branch history
included.

#### Scenario: An indexed evidence entry is deleted

- **WHEN** the issue run index names a run whose referenced evidence chain is missing an entry
- **THEN** harvesting rejects deleted-entry tampering rather than reporting that no run occurred

#### Scenario: An evidence comment is edited later

- **WHEN** the current body no longer matches its recorded digest
- **THEN** harvesting reports tampered evidence and does not silently replay it

### Requirement: Split evidence reassembles deterministically

When a payload exceeds the destination's size limit, it SHALL split only at the
projection layer into ordered, marked segments. Harvesting SHALL require the
complete trusted sequence and SHALL reconstruct the original validated payload
before computing metrics or exits.

#### Scenario: One segment is missing

- **WHEN** a stage projection declares three segments but only two authenticate
- **THEN** harvesting returns indeterminate rather than a partial trajectory

### Requirement: Run history is append-only and as-of reconstructable

Every run-record transition, intervention, and terminal-outcome entry SHALL carry
an immutable timestamp, sequence, previous-entry digest, and canonical digest.
Appending an entry SHALL extend that chain without editing an earlier entry. An
`--as-of` read SHALL first validate the complete chain, then reconstruct state
using only entries whose timestamps are at or before the cutoff. Editing or
deleting any entry SHALL break sequence or digest validation and fail closed.

#### Scenario: A transition occurs after the scoring cutoff

- **WHEN** a valid run enters integration after the requested `--as-of` timestamp
- **THEN** the reconstructed state excludes that transition and every later entry

#### Scenario: A historical intervention is edited

- **WHEN** an earlier intervention body changes without a new append-only entry
- **THEN** its digest no longer extends the recorded chain and run validation fails

### Requirement: The success metric uses a closed immutable cohort

Statistics SHALL report the share of kicked-off issues whose ready-reaching run
and all prior runs required zero human interventions, with blocked questions
reported separately as asked and human fixes after readiness reported as a
second failure measure. Cohort membership SHALL be fixed by first kickoff in
the reporting window and an observation cutoff; stale nonterminal runs SHALL be
terminalized as abandoned according to policy. Scoring at an earlier cutoff
SHALL reconstruct the run state from the validated append-only entries at that
cutoff rather than read only the latest comment body.

#### Scenario: A new retry starts after the cutoff

- **WHEN** an issue had a failed run before `--as-of` and a successful retry after it
- **THEN** the later retry neither removes the issue from the earlier cohort nor changes its earlier score

#### Scenario: A PR was promoted outside the orchestrator

- **WHEN** the PR timeline shows ready-for-review but the run record lacks the orchestrator's readiness fingerprint and promotion entry
- **THEN** the run is not counted as unattended success

### Requirement: Trajectories support inspection and policy replay

The statistics surface SHALL render one run's stages, round counts, findings by
class and provenance, exits, overrides, and interventions as machine-readable
JSON and a human table. Replay SHALL recompute every retained trajectory under
a candidate convergence policy and report every difference from its recorded
exit using read-only repository access.

#### Scenario: A candidate policy changes an old exit

- **WHEN** replay evaluates retained omator-style evidence under a new threshold
- **THEN** it reports the original and recomputed stage outcomes with the reason for the difference

### Requirement: Retrospectives begin with retained evidence

When a session's PR has a run record, the retro workflow SHALL start from the
rendered run trajectory and report per-stage rounds versus limits, finding
classes and provenance, overrides, and interventions. Improvements SHALL name
the stage, skill, config key, or registry contract they would change and SHALL
carry the run ID into any tracked follow-up. Sessions without a run record SHALL
use the existing fallback procedure.

#### Scenario: Retro finds repeated round-provenance findings

- **WHEN** the run trajectory shows a stage feeding on its own fixes
- **THEN** the improvement proposal cites that stage, its convergence policy or skill, and the originating run ID

### Requirement: Post-ready outcomes are derived at read time

Because the orchestrator stops at ready-for-review, merge, post-ready commits,
deployment, release, and smoke outcomes SHALL be derived from repository and PR
history rather than written into the run record. Delivery correlation SHALL use
the first delivery range that contains the merge commit.

#### Scenario: The merge commit appears in later releases too

- **WHEN** several later delivery ranges also contain the merge commit
- **THEN** statistics attribute the run to the first matching delivery only
