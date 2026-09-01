## Purpose

Defines the portable, versioned execution-policy vocabulary that every Dev
flow v2 consumer resolves identically before dispatching work or evaluating a
stage.

## ADDED Requirements

### Requirement: Version 2 is an incompatible policy shape

Every Dev flow v2 consumer SHALL require `schema_version = 2` and SHALL refuse
both the pre-v1 legacy shape and the v1 migrated shape with a migration message
that identifies the detected shape. No skill or script SHALL carry a fallback
interpreter for an older shape.

#### Scenario: A v1 policy reaches a v2 consumer

- **WHEN** a policy contains `[review.*]`, `[budget.*]`, or `[tier.*]` and does not conform to schema version 2
- **THEN** the consumer exits non-zero, identifies the v1 shape, and directs the operator to migrate the repository

### Requirement: Policy separates rounds, breadth, and spend

The policy SHALL represent vertical review appetite in `[rounds.*]`, horizontal
agent scale in `[breadth.*]`, and measurable cost ceilings only in optional
`[spend.*]` tables. Shipped rigor profiles SHALL reference one rounds policy
and one breadth policy; shipped policies SHALL omit spend ceilings when the
runtime cannot enforce them.

#### Scenario: A runtime cannot measure cost

- **WHEN** a shipped policy contains no `[spend.*]` table
- **THEN** the runtime reports spend enforcement as `UNENFORCED` and does not invent a token or currency limit

### Requirement: Rigor uses the revised six-level ladder

The policy SHALL define `rigor_order` as `cursory`, `light`, `standard`,
`thorough`, `deep`, and `forensic`, weakest to strongest. Every rigor profile
SHALL select rounds and breadth policies, five role tiers, and whether tier
escalation is permitted; the forensic rounds policy SHALL require at least two
rounds before the empty-round shortcut can end a confidence stage.

#### Scenario: Forensic receives an empty first round

- **WHEN** a forensic confidence stage completes its first round with no findings
- **THEN** the stage remains below its `min_rounds` floor and does not exit through the empty-round shortcut

### Requirement: Round limits have stage-specific meanings

The rounds policy SHALL bound challenge passes, review passes, Codex
integration cycles, integration remediation pushes, and whole-run wall-clock
time separately. A zero challenge or review limit SHALL disable only that
confidence stage; a zero integration limit SHALL waive only the Codex-verdict
condition; a zero remediation limit SHALL escalate the first finding that
requires a code fix. Hitting the wall-clock ceiling SHALL produce a blocker
report rather than silently trimming a stage.

#### Scenario: Integration review is disabled but a human finding exists

- **WHEN** `integration = 0` and a human finding is open on the draft PR
- **THEN** no Codex cycle is required, but the readiness gate remains blocked until the human finding is settled

#### Scenario: Remediation is exhausted

- **WHEN** the integration stage has spent its remediation allowance and another finding requires a fix push
- **THEN** the run records a capped integration outcome, lists the unresolved finding, and leaves the PR draft

### Requirement: Gates are repository-owned Taskfile target slugs

The `[gates]` table SHALL name `round_code`, `round_docs`, `secret_scan`, and
`pre_pr` as bare, existing Taskfile target slugs and SHALL hold the sole
`docs_only_paths` allowlist. A consumer SHALL compose `task <target>` and SHALL
reject values containing arguments, spaces, or paths. The push broker SHALL
recompute the diff classification rather than trust the caller's assertion.

#### Scenario: Config attempts to mint a shell command

- **WHEN** a gate value contains a space, slash, argument, or nonexistent Taskfile target
- **THEN** policy validation fails before the value can be executed

#### Scenario: A check-only marker covers a mixed diff

- **WHEN** a round push presents a docs-only gate marker but its merge-base diff includes a path outside `docs_only_paths`
- **THEN** the push broker rejects the marker and requires the configured code gate

### Requirement: Roles select and stages require

Each `[role.<slug>]` table SHALL provide a baseline tier plus ordered family
and harness preferences. Each `[stage.<stage>]` table SHALL use monomorphic
array keys: `finders` as all-of, `finder_fallbacks` as preference order, and
optional `pool` as an allowlist. Actor slugs and model choices SHALL resolve
through `agent-registry.json`; `.devflow.toml` SHALL NOT duplicate model-tier
tables or concrete model inventory.

#### Scenario: The preferred family has no compatible harness

- **WHEN** the first configured family has no available harness that implements the role
- **THEN** resolution falls through to the next family and records the substitution for disclosure

### Requirement: Self-modified policy resolves from the merge base

When a change edits `.devflow.toml` or `agent-registry.json`, every value that
can affect its own execution SHALL resolve from the merge-base copy, including
defaults, rigor profiles, rounds, breadth, spend, convergence, gates, roles,
stages, strategy, registry roles, write boundaries, and trusted actor IDs. An
attributable explicit operator instruction MAY override the merge-base value.

#### Scenario: A branch lowers its own code gate

- **WHEN** the branch changes `[gates].round_code` or expands `docs_only_paths`
- **THEN** its Dev flow run uses the merge-base gate and allowlist rather than the branch values

### Requirement: Policy validation is cross-file and fail-closed

Validation SHALL verify threshold ranges, vocabulary permutations, nonempty
allowlists, strategy compatibility with breadth, role-tier invariants, and all
role, family, harness, finder, pool, and gate references against the registry
and Taskfile. An unreadable or inconsistent dependency SHALL be indeterminate,
not a defaultable success.

#### Scenario: A stage names an unknown finder

- **WHEN** `[stage.review].finders` contains a slug absent from the registry
- **THEN** validation fails and no review round is dispatched
