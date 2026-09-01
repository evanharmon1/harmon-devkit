## Purpose

Defines deterministic receipt validation and confidence-stage exit computation
from policy, role results, adjudications, repository history, and current-head
state.

## ADDED Requirements

### Requirement: Results are validated before interpretation

Every role result SHALL use the version 2 envelope, bind to the active run's
identity and initiating actor, and agree with its payload on any named head.
The orchestrator's trusted receipt sequence SHALL order passes and transitions,
cross-checked against GitHub event order where cross-checkable. A result's
trusted receipt SHALL fall after run start and its producing-stage entry and
before promotion. Producer-supplied `produced_at` SHALL be only a bounded sanity
check under a declared clock-skew tolerance, never an ordering or authentication
boundary. A result SHALL belong to its producing stage; a pass from an earlier
stage SHALL NOT count in a later stage even when both name the same head.
Finding IDs SHALL be unique across the run. The orchestrator SHALL validate
identity, chronology, stage, and payload agreement before reading a result's
recommendation or evidence. The chronology-attack fixtures enumerated in
`tasks.md` SHALL exercise these boundaries.

#### Scenario: A stale retry returns into a newer run

- **WHEN** a schema-valid result names a `run_id` or `initiated_by` different from the active branch pointer's run
- **THEN** receipt validation rejects the result and it contributes no pass or finding

#### Scenario: A producer clock disagrees with receipt order

- **WHEN** a result's `produced_at` conflicts with receipt order but remains within the declared skew tolerance
- **THEN** validation orders the pass by trusted receipt sequence and does not let the producer timestamp move it across a stage boundary

#### Scenario: An earlier-stage pass names the same head

- **WHEN** a challenge pass and the active review stage name the same commit
- **THEN** the challenge pass cannot satisfy a review finder slot or contribute to the review round

#### Scenario: Stage transitions are out of order

- **WHEN** receipt sequence or cross-checkable GitHub event order does not form one strict lifecycle order
- **THEN** trajectory validation fails before any result contributes to exit computation

### Requirement: Logical rounds require every configured finder

A confidence-stage logical round SHALL contain one completed pass from every
configured primary finder slot at one `reviewed_head`. A blocked primary SHALL
receive its single retry before the configured `finder_fallbacks` chain for that
slot is attempted in order. Every substitution SHALL be recorded and disclosed,
and the round SHALL retain exactly one completed pass for each configured primary
slot. Each retained pass SHALL have exactly one adjudication document and each
adjudication SHALL refer to one retained pass. Only exhaustion of the primary's
retry and complete fallback chain SHALL yield `capped` with reason
`finder_unavailable`; a round SHALL NOT silently proceed with fewer slots.

#### Scenario: One of two review finders is unavailable

- **WHEN** one primary slot completes and the other remains blocked after its primary retry and every configured fallback attempt
- **THEN** no logical round is counted and the stage returns `capped` with the exhausted primary slot and attempted substitutions named

#### Scenario: A fallback substitutes for a blocked primary

- **WHEN** a primary remains blocked after its retry and the next configured fallback completes at the shared head
- **THEN** the run records and discloses the substitution and counts its pass exactly once for that primary slot

### Requirement: Exit computation is deterministic and ordered

For the same validated trajectory, resolved policy, and current head, every
implementation SHALL return the same outcome and reason. The evaluator SHALL
apply precedence in this order: `capped`, `diverging`, `converged`, then
`continue`. Reviewer or challenger recommendations SHALL NOT determine the
outcome.

#### Scenario: The final permitted round is also diverging

- **WHEN** the cap is reached on a trajectory that satisfies a divergence predicate
- **THEN** the outcome is `capped`, because the cap forbids the extra remediation round divergence would otherwise require

### Requirement: Convergence is gated by current-head cleanliness

`converged` SHALL require zero adjudicated P0 or P1 findings of every class on
a logical round that reviewed the current head, a configured convergence
predicate, and the effective minimum rounds. A zero-finding round MAY end the
stage once its minimum is met. A final clean round at the cap SHALL be
capped-clean without requiring a forbidden confirmation round.

#### Scenario: Reviewer reports clean below the floor

- **WHEN** a clean logical round completes before the effective `min_rounds`
- **THEN** the evaluator returns `continue` and does not consult the reviewer's exit recommendation

#### Scenario: The capped final round is clean

- **WHEN** the last permitted round reviewed the current head and has zero adjudicated P0/P1 findings
- **THEN** the stage may advance as capped-clean without another round

### Requirement: Provenance and fingerprint assertions are verified

The evaluator SHALL verify `original`, `round:N`, `repeat-of`, and `supersedes`
assertions against repository and run evidence, recording any correction and
its evidence. An undecidable assertion SHALL remain `unverified`, retain its
adjudicated priority for gating, and be excluded from predicates that require
verified provenance without disappearing from total counts.

#### Scenario: A finding claims original provenance on round-one code

- **WHEN** evidence proves the implicated behavior was introduced by round 1's fix
- **THEN** computation uses `round:1` for provenance predicates and records the disagreement

#### Scenario: A deleted line prevents mechanical attribution

- **WHEN** the evaluator cannot reliably attribute a finding after the fix deleted its original line
- **THEN** the finding is marked unverified, still blocks if adjudicated P1, and cannot alone satisfy a provenance-share predicate

### Requirement: Divergence detects self-feeding remediation

Divergence predicates SHALL evaluate only adjudicated P0/P1 findings and SHALL
detect verified provenance share, strictly rising gating-finding counts with a
verified round-provenance guard, and repeats after a code-changing disposition.
A repeat after `decline` SHALL NOT count as a repeat after fix. A diverging
stage SHALL permit only `delete` or `restructure` dispositions on the
round-provenance findings; otherwise it SHALL stop with a blocker.

#### Scenario: A fixed finding repeats

- **WHEN** a current finding is verified as a repeat of an earlier finding whose disposition changed code
- **THEN** the repeat-after-fix predicate is true even if the fix rewrote or renamed the implicated line

#### Scenario: Divergence is answered with another hardening fix

- **WHEN** a diverging outcome has only `fix` dispositions for its round-provenance findings
- **THEN** the stage refuses another fix round and reports the required delete-or-restructure decision

### Requirement: Head ancestry controls usable evidence

Only a logical round that reviewed the current head SHALL satisfy convergence
or capped-clean. Ancestor-head rounds MAY inform trajectory predicates and
minimum-round counts. Rounds on incomparable heads SHALL be excluded and yield
`continue` with reason `invalidated` when no valid current-head exit remains.

#### Scenario: A P2 fix lands after a clean review

- **WHEN** any commit is added after the clean round, including a P2-only fix
- **THEN** the clean ancestor round cannot certify the new head and another permitted round is required

### Requirement: Caps constrain retained trajectory records

No confidence pass or adjudication round number SHALL exceed its resolved
stage cap, and a cap-zero confidence stage SHALL contain no rounds. Integration
cycle numbers and remediation loops SHALL remain within their separate limits;
code-changing integration dispositions past remediation SHALL be rejected.
Legal stage skipping SHALL require the corresponding cap-zero policy.

#### Scenario: A disabled challenge stage contains a pass

- **WHEN** challenge has cap zero but the trajectory includes challenge round 1
- **THEN** receipt validation rejects the trajectory as inconsistent with its resolved policy

### Requirement: Exit tools expose a stable machine contract

The exit surface SHALL return a structured verdict containing outcome, reason,
rounds counted, and next round, with distinct terminal codes for continue,
converged, diverging, capped, and indeterminate. DevKit and Foreman SHALL accept
and reject the same conformance fixtures at a pinned contract version.

#### Scenario: Two consumers replay the same fixture

- **WHEN** DevKit's tool and Foreman's implementation evaluate the pinned trajectory and policy fixture
- **THEN** both produce the same outcome and reason or the conformance test fails
