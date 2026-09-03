## Purpose

Defines durable, authenticated Dev flow run and round evidence from kickoff
through ready-for-review so failed runs, metrics, replay, and retrospectives do
not depend on a surviving branch or session memory.

## ADDED Requirements

### Requirement: Every issue-bound kickoff reserves a durable run record

The durable run-record protocol SHALL apply to issue-bound runs. The actor
kicking off such a run SHALL create a unique run identity and reserve its
run-record comment on the issue before any branch or PR is required. A
topic-only `/kickoff` SHALL remain outside the version 2 run contract until an
issue exists and SHALL NOT invent an issue merely to satisfy this protocol. The
local working copy SHALL live under the repository's common git directory keyed
by run ID, with a branch pointer added once a branch exists, so linked worktrees
share the record and reused branch names do not reuse trajectories.

#### Scenario: A run dies before creating a branch

- **WHEN** an issue-bound kickoff was recorded but the environment disappears before a branch is created
- **THEN** harvesting identifies the run by issue and `run_id` alone, terminalizes it as `capped-pre-branch`, and creates no branch-pointer collision

### Requirement: Role outputs and adjudications remain immutable

Raw role results and adjudication records SHALL be immutable after receipt.
Run history, including stage transitions, interventions, evidence-comment
registrations, the PR binding, and the terminal outcome, SHALL live in
append-only run-record entries rather than editable summary fields. Deferred-
finding terminal settlements SHALL likewise be append-only, keyed by finding
ID, and SHALL NOT rewrite the original evidence comment or adjudication
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
`run_id`, `initiated_by`, a nullable `branch`, and the run-record digest where
the claim lives on the issue. The branch SHALL be null at creation; once a
branch exists, one subsequent digest-chained entry SHALL bind that branch to the
run and the branch pointer SHALL name the same run. Before that binding, the
issue plus `run_id` SHALL identify the run without colliding with any branch
pointer. The run record SHALL store evidence comment IDs, immutable author actor
IDs, display logins, canonical SHA-256 payload digests, and marker sequence. A
harvester SHALL accept only comments named by the trusted run record whose
current author and body match those values. The issue-level index and, once it
exists, the branch pointer—not the continued existence of deletable evidence
comments—SHALL anchor run discovery. If an indexed run's evidence chain is
missing or broken, the harvester SHALL reject it as deleted-entry tampering,
never reinterpret it as a run that did not happen.
The run-record author's authority SHALL derive solely from configured
trusted orchestrator actor IDs — the registry's trusted actors, declared in
`agent-registry.json`, the same finder trust IDs already use — never an
identity declared inside the record and never a kickoff-shaped event alone,
which proves nothing about who posted it. The digest chain defends against
non-trusted actors and
accidental edits; a compromised trusted-account token is explicitly out of
scope because it defeats every mechanism in the repository, branch history
included. Trust evaluation for a given run SHALL be pinned to an
authoritative registry revision for that run (its kickoff-time snapshot, or
an equivalent effective-time binding) rather than whatever the registry
currently declares — an actor added to the allowlist after a run's evidence
was posted SHALL NOT retroactively authenticate that evidence, and an actor
later removed SHALL NOT invalidate evidence that was authenticated while
they were still trusted.

#### Scenario: A run record's author is not a configured trusted actor

- **WHEN** the run record comment's author is not among the repository's configured trusted-orchestrator actor IDs
- **THEN** harvesting rejects the run record and its evidence as unauthenticated rather than accepting an unproven identity

#### Scenario: An actor is added to the allowlist after a run's evidence was posted

- **WHEN** a run's evidence was authored by an actor not on the allowlist at kickoff time, and that actor is added to the allowlist later
- **THEN** harvesting evaluates authenticity against the run's own kickoff-time registry revision and does not retroactively accept that evidence

#### Scenario: A trusted actor is removed from the allowlist after posting

- **WHEN** a run's evidence was authored by an actor trusted at the time it was posted, and that actor is later removed from the allowlist
- **THEN** harvesting continues to accept that already-authenticated evidence rather than invalidating history that was valid when it was recorded

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

Every run-record transition, intervention, evidence-comment registration,
PR-binding, and terminal-outcome entry SHALL carry an immutable timestamp,
sequence, previous-entry digest, and canonical digest.
Appending an entry SHALL extend that chain without editing an earlier entry. An
`--as-of` read SHALL first normalize exact-duplicate entries (below), then
validate the complete chain, then reconstruct state using only entries whose
timestamps are at or before the cutoff. Editing or deleting any entry SHALL
break sequence or digest validation and fail closed.

Within one run there is exactly one writer: the orchestrating session,
appending reserve-first — unlike an evidence comment, a run-record entry is
not itself a separate GitHub comment with its own comment ID to canonicalize
by, since every entry lives inside the one run-record comment edited in
place. Two entries that are byte-identical are a harmless duplicate (a
resumed writer's own retry re-appending an entry that already landed) and
SHALL be normalized to one **before** raw sequence/digest chain validation
runs — a byte-identical retry necessarily repeats both its sequence and
previous-entry digest, so validating the un-normalized chain first would
reject it as broken rather than recognize it as the harmless case it is.
Two entries that instead claim the same previous-entry
digest but carry *different* content are a **forked** chain, not a
duplicate — harvesting SHALL fail closed and report the run indeterminate
rather than choosing either branch as canonical. Concurrent writers from
more than one orchestrator session are out of scope, the same GitHub
read-modify-write limitation already disclosed elsewhere in this family:
nothing here claims to close it. Repeatability SHALL hold for the chain as
durably observed, not for an event's own self-reported timestamp: an entry
reserved before a cutoff but not yet landed at read time is not part of any
chain a reader can see yet, so a later re-read that then includes it
reflects what has newly landed, never a violation of "the same cutoff over
the same materialized chain reports the same result."

#### Scenario: The run-record chain forks

- **WHEN** two entries in a run's history both name the same previous-entry digest but carry different content
- **THEN** harvesting reports the run indeterminate and does not choose either branch as canonical

#### Scenario: An entry lands after an earlier read at the same cutoff

- **WHEN** an entry timestamped at or before cutoff `C` is reserved before a first `--as-of C` read but its run-record write does not durably land until after that read completes
- **THEN** the first read's result reflects the chain as it was durably observed at that time, and a later `--as-of C` read that now includes the landed entry is not a repeatability violation

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
