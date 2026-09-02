## Purpose

Defines the portable, versioned execution-policy vocabulary that every Dev
flow v2 consumer resolves identically before dispatching work or evaluating a
stage.

## ADDED Requirements

### Requirement: Version 2 is an incompatible policy shape

Every Dev flow v2 consumer SHALL require `schema_version = 2` and SHALL refuse
both the pre-v1 legacy shape and the v1 migrated shape with a migration message
that identifies the detected shape from its controlling markers. Shape detection
SHALL NOT use `[tier.*]`, which can occur in either older shape. The v1 migrated
shape SHALL be identified by `rigor_order`, `[review.*]` tables, and the
`[rigor.<level>].review` pointers into those tables. The pre-v1 legacy shape SHALL
be identified by challenge, review, shepherd, and minimum-round caps directly on
`[rigor.<level>]` together with `default_method` and `[method]`. A mixed or
incomplete marker set SHALL be rejected with the markers it actually contains,
not guessed into either shape. No skill or script SHALL carry a fallback
interpreter for an older shape as an active policy: the sole permitted reading
of an older shape is the merge-base path of a change that migrates the policy,
where the older copy is decoded under its own declared shape and never used
as the policy a consumer operates under.

#### Scenario: A v1 policy reaches a v2 consumer

- **WHEN** a policy has `rigor_order`, `[review.*]`, and rigor-to-review pointers but does not conform to schema version 2
- **THEN** the consumer exits non-zero, identifies the v1 shape, and directs the operator to migrate the repository

#### Scenario: A legacy policy carries tier tables

- **WHEN** a policy has caps directly on `[rigor.*]`, `default_method`, and `[method]` and also contains `[tier.*]`
- **THEN** the consumer identifies the legacy shape from its rigor and method markers and directs the operator to migrate it

#### Scenario: The tooling's own repository has not migrated

- **WHEN** a v2 consumer's test suite runs in a repository whose live `.devflow.toml` is still legacy or v1
- **THEN** the suite evaluates shipped fixture policies and passes, while any direct invocation against the live file refuses it with the migration message

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
SHALL select rounds and breadth policies and whether tier escalation is
permitted, and MAY supply a tier for any role. For every role, validation SHALL
require a tier to be resolvable from either the rigor profile or that role's
`[role.<slug>]` baseline; a profile is not required to repeat all five role
tiers. The forensic rounds policy SHALL require at least two rounds before the
empty-round shortcut can end a confidence stage.

#### Scenario: Forensic receives an empty first round

- **WHEN** a forensic confidence stage completes its first round with no findings
- **THEN** the stage remains below its `min_rounds` floor and does not exit through the empty-round shortcut

### Requirement: Round limits have stage-specific meanings

The rounds policy SHALL bound challenge logical rounds, review logical rounds,
Codex integration cycles, integration remediation pushes, and whole-run
wall-clock time separately. One challenge or review logical round SHALL consist
of one completed pass for every configured primary finder slot; the challenge
and review limits SHALL count that aggregate round once and SHALL NOT count its
individual finder passes. A zero challenge or review limit SHALL disable only
that confidence stage; a zero integration limit SHALL waive only the Codex-
verdict condition; a zero remediation limit SHALL escalate the first finding
that requires a code fix. Hitting the wall-clock ceiling SHALL produce a
blocker report rather than silently trimming a stage.

#### Scenario: A multi-finder round spends one unit of its cap

- **WHEN** a review logical round completes one pass for each of three configured primary finder slots
- **THEN** the review cap advances by one logical round, not by three finder passes

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
tables or concrete model inventory. A role tier supplied by the resolved rigor
profile SHALL override that role's `[role.<slug>]` baseline; the baseline SHALL
apply only when the profile omits a tier for that role. After that profile-or-
baseline selection, applicable tier labels SHALL refine the role tier under the
normal explicit-instruction, trusted-label, and capability-escalation precedence
rules.

#### Scenario: Rigor overrides a role baseline before label refinement

- **WHEN** the resolved rigor profile supplies a reviewer tier that differs from `[role.reviewer].tier` and an authorized reviewer-tier label also applies
- **THEN** resolution starts from the rigor profile's reviewer tier, ignores the baseline for that role, and then applies the label under the tier precedence rules

#### Scenario: A rigor profile omits one role tier

- **WHEN** the resolved rigor profile omits the integrator tier and `[role.integrator].tier` is present
- **THEN** the integrator baseline supplies the tier before any applicable tier label refines it

#### Scenario: Neither profile nor role supplies a tier

- **WHEN** a rigor profile omits a role's tier and that role has no baseline tier
- **THEN** policy validation fails because the role cannot be resolved

#### Scenario: The preferred family has no compatible harness

- **WHEN** the first configured family has no available harness that implements the role
- **THEN** resolution falls through to the next family and records the substitution for disclosure

### Requirement: Self-modified policy resolves from the merge base

When a change edits `.devflow.toml`, `agent-registry.json`, or any file in
the policy reader's trusted closure (the reader, its built-in defaults, and
the historical decoder), every value that can affect its own execution SHALL
resolve from the merge-base copy by executing the merge-base reader from a
materialized closure, including defaults, rigor profiles, rounds, breadth,
spend, convergence, gates, roles, stages, strategy, registry roles, write
boundaries, and trusted actor IDs. An attributable explicit operator
instruction MAY override the merge-base value.

#### Scenario: A branch edits the reader's built-in defaults

- **WHEN** a migration branch changes the policy reader or the defaults it supplies for values the older shape never declared
- **THEN** resolution executes the merge-base reader from its materialized closure, so the branch's defaults do not take part in the run that reviews them

#### Scenario: A branch lowers its own code gate

- **WHEN** the branch changes `[gates].round_code` or expands `docs_only_paths`
- **THEN** its Dev flow run uses the merge-base gate and allowlist rather than the branch values

#### Scenario: A branch migrates the policy shape

- **WHEN** the change under review replaces a v1 or legacy `.devflow.toml` with a `schema_version = 2` file
- **THEN** the run resolves its caps, floor, and gates from the merge-base copy interpreted under that copy's own declared shape, while the branch copy must still validate as version 2 and an active older shape is still refused

#### Scenario: A legacy cap bounds both integration limits

- **WHEN** the merge-base copy is the legacy shape whose `shepherd` cap bounded fix pushes and no-change cycles together
- **THEN** the decoded policy sets both `integration` and `remediation` to that `shepherd` value and marks them as one shared budget, so the integration stage counts every Codex cycle and every fix push against a single total of `shepherd` rounds, exactly as the legacy contract did; the migration run can neither gain rounds nor cap earlier than the older policy allowed

#### Scenario: A migration branch edits a value the older shape never declared

- **WHEN** the merge-base copy is an older shape with no breadth, convergence, finder, role, or trusted-actor declarations and the branch copy sets any of them
- **THEN** the run resolves those values from the consumer's built-in defaults, not from the branch copy, and the resolved policy is identical whatever the branch copy declares

### Requirement: Gate authority separates policy from branch implementation

Merge-base resolution SHALL determine gate policy, including required target
slugs, allowlists, and thresholds. Before any round push, the orchestrator SHALL
materialize outside the feature worktree and execute the merge-base
implementations of both the secret scan and the round-push broker, for example
by extracting each path with `git show <merge-base>:<path>`. Both
implementations SHALL live at stable repository-owned paths that stage skills
reference rather than vendor, so the merge-base extraction survives a skill
rename. The materialized unit SHALL be each implementation's full trusted
closure: the broker, the policy reader, the secret scanner and its
configuration, and their control and configuration dependencies, extracted
from the merge base together and consumed through explicit paths, so that
no part of the gate-authority decision resolves a worktree-resident file.
The configured round gate itself (`round_code` or `round_docs`) is not part
of that closure: the merge-base broker selects it, and then executes it
from the feature worktree, where its result is branch-attested evidence. This boundary is
mandatory because a secret is public when the push lands and PR CI is too late.
A branch that edits either implementation SHALL exercise its changed version in
required PR CI, but SHALL NOT use that version to authorize its own push. Every
other local gate SHALL execute its branch implementation and record branch-
attested evidence. The deterministic readiness authorities SHALL be the merge-
base-resolved policy and the PR's concluded required CI checks; branch-attested
local evidence SHALL NOT substitute for a required check conclusion.

#### Scenario: A branch modifies only a gate dependency

- **WHEN** a branch changes only the policy reader or the secret scanner's configuration and leaves the broker and scan entrypoints untouched
- **THEN** the pre-push gate still executes the merge-base copies of those dependencies, and the branch versions are exercised only by required PR CI

#### Scenario: A branch modifies pre-push enforcement

- **WHEN** a branch changes the secret scanner or round-push broker before a round push
- **THEN** the push executes both merge-base implementations outside the worktree, while required PR CI exercises the branch versions

#### Scenario: A branch attests its modified local gate

- **WHEN** a branch changes a gate implementation, produces passing local evidence, and its corresponding required PR check has not concluded
- **THEN** the run records the local evidence as branch-attested and readiness remains blocked on the required check

### Requirement: Policy validation is cross-file and fail-closed

Validation SHALL verify threshold ranges, vocabulary permutations, nonempty
allowlists, strategy compatibility with breadth, role-tier invariants, and all
role, family, harness, finder, pool, and gate references against the registry
and Taskfile. An unreadable or inconsistent dependency SHALL be indeterminate,
not a defaultable success.

#### Scenario: A stage names an unknown finder

- **WHEN** `[stage.review].finders` contains a slug absent from the registry
- **THEN** validation fails and no review round is dispatched
