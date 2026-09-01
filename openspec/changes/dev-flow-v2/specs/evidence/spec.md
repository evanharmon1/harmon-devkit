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
Mutable run state, including interventions, transitions, outcome, and PR, SHALL
live only in the run record. Deferred-finding terminal settlements SHALL be
append-only, keyed by finding ID, and SHALL NOT rewrite the original evidence
comment or adjudication digest.

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
reservation locally. On resume it SHALL search the destination for that marker
and adopt only a matching comment authored by the run's trusted actor; an
untrusted matching marker SHALL be reported and SHALL NOT suppress the
legitimate write.

#### Scenario: Posting succeeds but the comment ID is not recorded

- **WHEN** interruption occurs after the trusted comment is created
- **THEN** a resumed writer adopts the existing comment by marker and records its ID without creating a duplicate

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

The run record SHALL store evidence comment IDs, immutable author actor IDs,
display logins, canonical SHA-256 payload digests, and marker sequence. A
harvester SHALL accept only comments named by the trusted run record whose
current author and body match those values. The run-record author's authority
SHALL derive from configured trusted orchestrator actor IDs or the trusted
kickoff event, never an identity declared inside the record.

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

### Requirement: The success metric uses a closed immutable cohort

Statistics SHALL report the share of kicked-off issues whose ready-reaching run
and all prior runs required zero human interventions, with blocked questions
reported separately as asked and human fixes after readiness reported as a
second failure measure. Cohort membership SHALL be fixed by first kickoff in
the reporting window and an observation cutoff; stale nonterminal runs SHALL be
terminalized as abandoned according to policy. Scoring at an earlier cutoff
SHALL reconstruct the run state at that cutoff rather than read only the latest
edited comment body.

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
