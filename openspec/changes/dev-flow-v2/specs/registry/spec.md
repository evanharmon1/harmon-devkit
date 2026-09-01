## Purpose

Defines the validated inventory of Dev flow roles, finders, harnesses, model
families, and permitted writes that portable policy and result contracts refer
to by slug.

## ADDED Requirements

### Requirement: Registry roles are explicit contracts

The registry SHALL declare orchestrator, implementer, challenger, reviewer,
and integrator roles. Each role SHALL name its result schema where applicable
and enumerate its permitted external writes; an agent definition implementing a
role SHALL use the same role slug.

#### Scenario: An agent definition has no registry role

- **WHEN** an `ai/agents/*.md` name does not resolve to a registry role
- **THEN** agent validation fails before the definition is vendored

### Requirement: Challenger and reviewer are distinct roles

The challenger contract SHALL produce adversarial attack scenarios,
design-level findings, and de-scaffolding recommendations. The reviewer
contract SHALL produce implementation consistency evidence and test-gap
findings. Both SHALL use the common finding core, but neither SHALL be treated
as the other's contract merely because both feed exit computation.

#### Scenario: Challenge dispatch resolves a role

- **WHEN** the orchestrator dispatches a finder configured for the challenge stage
- **THEN** the returned pass conforms to the challenger role's result contract rather than a hard-coded reviewer payload

### Requirement: Write boundaries are enforced capabilities

The implementer SHALL be permitted to create branch commits and invoke the
round-push broker. The challenger and reviewer SHALL have no external writes.
The integrator SHALL be limited to a brokered Codex trigger and a brokered
thread reply containing text supplied by the orchestrator. A harness that
cannot deny ambient writes SHALL NOT dispatch a write-restricted role.

#### Scenario: A plain subagent inherits a writable GitHub token

- **WHEN** the harness cannot restrict tools or credentials for a reviewer or integrator dispatch
- **THEN** the orchestrator refuses the dispatch rather than merely disclosing the excess authority

### Requirement: Finders declare collection and trust metadata

Each finder SHALL declare a stable slug, display name, surface, role or result
contract, stage affinity, invocation or collection protocol, and immutable
actor ID where a remote bot identity is trusted. Pre-PR stages SHALL use only
finders whose surface is available before a PR exists.

#### Scenario: A PR-only finder is configured for challenge

- **WHEN** a finder with a `pr-cloud` surface is listed for a pre-PR challenge stage
- **THEN** cross-file validation rejects the configuration

### Requirement: Model strata live in registry inventory

Every registered family model SHALL carry one tier from `local`, `economy`,
`standard`, `frontier`, or `apex`. When a family has multiple models at one
tier, at most one SHALL be marked as that family's default for the tier.
Escalation SHALL move through the policy's tier order while retaining the
resolved family; it SHALL NOT use a duplicated per-policy model map.

#### Scenario: Two models claim the same family-tier default

- **WHEN** two models in one family and tier are both marked `default`
- **THEN** registry validation fails as ambiguous

### Requirement: Harnesses advertise executable role support

Every harness SHALL declare the families and roles it can run, including the
challenge, review, and integration split. Role resolution SHALL select a
family first and then the first compatible, available harness within that
family; an incompatible harness SHALL be skipped without changing families.

#### Scenario: Preferred harness lacks the resolved family

- **WHEN** a role's first harness preference does not support the resolved family
- **THEN** resolution tries the next compatible harness and records the selected harness

### Requirement: Labels resolve role names through the registry

Any `tier:<role>:<tier>` control label SHALL resolve `<role>` against the
registry and `<tier>` against the shared tier order. Concrete label values
SHALL be explicitly declared in the label vocabulary; the registry SHALL NOT
silently generate or apply them.

#### Scenario: A label names an unknown role

- **WHEN** policy resolution encounters a tier label whose role slug is absent from the registry
- **THEN** the label is rejected or ignored according to label-validation policy and cannot alter dispatch
