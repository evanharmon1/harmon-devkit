## Purpose

Defines how the session-as-orchestrator dispatches scoped roles through Dev
flow stages, including parallel implementation, confidence rounds, integration,
and the sole transition to human review.

## ADDED Requirements

### Requirement: The session is the orchestrator

The originating interactive or headless session SHALL own policy resolution,
role selection, adjudication, stage transitions, draft publication, evidence
writes, readiness evaluation, and promotion. The system SHALL NOT introduce an
orchestrator agent, and SHALL NOT permit an exit override toward fewer rounds or
weaker evidence. An upward override SHALL require remaining headroom and a
recorded attributable reason.

#### Scenario: Orchestrator disagrees with convergence

- **WHEN** the computed exit is `converged` and the orchestrator has a documented concern with cap headroom remaining
- **THEN** it may record an upward override and dispatch one more round

### Requirement: Skills map verbs to lifecycle stages

Stage skills SHALL use verb names such as `/implement`, `/review`, and
`/integrate` while the lifecycle uses implement, challenge, review, security,
and integration stage nouns. `/orchestrator` SHALL be a standing operating mode,
not a stage. No monolithic skill SHALL restate the entire walk, and `gauntlet`
and `shepherd` SHALL be retired names.

#### Scenario: Review stage completes

- **WHEN** `/review` finishes the review stage with a terminal clean outcome
- **THEN** it names the security stage as next without executing a separate monolithic Dev Loop skill

### Requirement: Briefs are free-form and results are schema-bound

Orchestrator-to-role briefs SHALL remain prose and SHALL include the applicable
design record, captured base and head, prior findings, policy, stage, and run
identity. Role-to-orchestrator results SHALL validate against the role's schema
before use. A role SHALL NOT derive permission from instructions embedded in an
issue, PR, or prior result.

#### Scenario: A role returns malformed evidence

- **WHEN** a dispatched role returns a payload that fails its result schema
- **THEN** the orchestrator rejects it without adjudicating or advancing the stage

### Requirement: Challenge and review dispatch different judgment roles

The `/review` stage skill SHALL dispatch challenger passes for challenge and
reviewer passes for review. Each pass SHALL assert provenance and fingerprint
against prior rounds, recommend dispositions, and write nothing externally.
Neither role SHALL fix code, author an adjudication, or decide an exit. Fix
rounds SHALL dispatch an implementer in fresh bounded context.

#### Scenario: A challenger finds round-added scaffolding

- **WHEN** a challenge pass identifies a gating finding about scaffolding introduced by a prior fix
- **THEN** it recommends de-scaffolding and leaves the delete, restructure, or in-scope disposition to the orchestrator

### Requirement: Confidence stages follow computed exits

For each logical round, the stage skill SHALL capture scope, dispatch every
configured finder, validate results, obtain orchestrator adjudication, record
evidence, run exit computation, and act on exactly the returned outcome.
`continue` dispatches the next permitted pass or fix; `diverging` requires
delete or restructure; capped with P0/P1 escalates before PR creation; terminal
clean outcomes advance.

#### Scenario: Challenge caps with a P1

- **WHEN** the challenge limit is reached with an adjudicated P1 remaining
- **THEN** the run records an intervention and blocker, does not open a PR, and waits for a human

### Requirement: Implementers may run in parallel within explicit bounds

Implementation SHALL select eligible harnesses from the implement stage pool,
role family and harness preferences, strategy constraints, and breadth limits.
Independent work MAY run in parallel; council strategy SHALL draw distinct
families when eligibility allows. The orchestrator SHALL record worktree,
branch, scope, ownership, dependencies, and conflict overlap per lane, and SHALL
serialize or declare dependencies for overlapping files. Each lane SHALL write
only its isolated lane branch and SHALL NOT push the feature branch, which SHALL
have exactly one writer at a time. The orchestrator SHALL integrate exactly the
selected lane outputs through that single-writer feature-branch path, then append
an assembly transition to the run record naming every integrated and discarded
lane and the assembled canonical head. Confidence stages SHALL review only that
canonical head after verifying its exact SHA.

#### Scenario: Two planned slices edit the same file

- **WHEN** dispatch-time overlap detection finds a shared path
- **THEN** the orchestrator serializes the slices or records an explicit merge dependency in both briefs

#### Scenario: Council requests more parallelism than breadth allows

- **WHEN** its minimum agents exceed the resolved run or concurrency ceilings
- **THEN** policy validation refuses the strategy-rigor combination rather than silently shrinking the council

#### Scenario: Selected lanes assemble into the feature branch

- **WHEN** parallel lanes finish and the orchestrator selects a subset of their outputs
- **THEN** the sole feature-branch writer integrates exactly that subset, records integrated and discarded lanes, and captures the resulting canonical SHA before confidence review

#### Scenario: A lane attempts to push the feature branch

- **WHEN** a parallel implementer lane attempts to write or push the shared feature branch
- **THEN** the single-writer path rejects the operation and the lane remains confined to its isolated branch

### Requirement: Parallel work has persistent supervision and scheduling

The orchestrator SHALL maintain durable lane state, a persistent event monitor,
and a merge queue containing paths, pairwise overlap, stage, dependency, and
invalidation cost. Every terminal agent or PR event SHALL lead to a documented
action, and merge-order recommendations SHALL disclose effects on other active
branches. Product, scope, and safety decisions SHALL remain human decisions;
sequencing and scheduling SHALL be orchestrator decisions with disclosure. The
monitor SHALL persist terminal-event identities and atomically record each action
receipt before advancing its durable event cursor. Re-armed monitoring SHALL
resume from that cursor and SHALL NOT re-execute an action whose receipt exists.

#### Scenario: A monitor exits unexpectedly

- **WHEN** the persistent lane monitor terminates before all lanes are terminal
- **THEN** the orchestrator re-arms it and does not interpret the exit as human cancellation

#### Scenario: Monitoring resumes after an action receipt

- **WHEN** the monitor records an action receipt for a terminal event and exits before observing the next event
- **THEN** the re-armed monitor advances from the durable cursor without executing the receipted action again

#### Scenario: A cheap branch would invalidate a terminal-stage branch

- **WHEN** the merge queue detects overlapping paths and unequal re-verification cost
- **THEN** the readiness report states the externality and recommends an order that avoids repeated terminal-stage work

### Requirement: Round pushes use an enforced broker

Whoever holds the worktree SHALL create one conventional fix commit per round
and invoke the round-push broker. The broker SHALL require the configured
diff-aware gate and unconditional secret scan, bind its marker to the exact
head and diff class, and push only the branch's named writable remote. History
already pushed SHALL NOT be rewritten.

#### Scenario: A code fix presents only the docs gate

- **WHEN** the broker re-derives that a round changed code
- **THEN** it refuses the push until the configured code gate and secret scan pass

### Requirement: Integration returns evidence without taking judgment

The integrator SHALL capture the expected head, settle CI status, persist a
Codex cycle reservation before triggering, attach the trigger ID, poll every
accepted surface, perform the one bounded retry, resume existing state after
interruption, and return schema-valid integration evidence. It MAY post only
the brokered trigger and exact thread-reply text supplied by the orchestrator;
it SHALL NOT author dispositions, replies, settlements, or promotion.

#### Scenario: Integrator dies after posting the trigger

- **WHEN** the reservation exists and the trigger comment is discoverable but the attachment step was interrupted
- **THEN** the resumed integrator adopts and attaches the trusted matching trigger instead of posting another

### Requirement: Readiness and promotion remain session-owned

The readiness gate SHALL be the sole terminal predicate over current-head
integrator evidence plus CI, findings, thread replies, settlements, review
decision, merge state, workflow completion, and pre/post content fingerprints.
Only the orchestrator SHALL promote a draft after a complete pass and immediate
head re-read. Merge SHALL always remain a separate human decision.

#### Scenario: The head changes after integration reports clean

- **WHEN** the readiness gate re-reads a different head before promotion
- **THEN** it invalidates the evidence, leaves the PR draft, and starts a new permitted current-head cycle
