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
`standard`, `frontier`, or `apex`. When a family has more than one model at one
tier, exactly one SHALL carry `default: true`; registry validation SHALL reject
both no default and multiple defaults. A family-tier rung containing one model
needs no default flag. Escalation SHALL move through the policy's tier order
while retaining the resolved family; it SHALL NOT use a duplicated per-policy
model map. During initial role resolution, a family that has a compatible
harness but no model at the resolved tier SHALL be unavailable for that
resolution. Resolution SHALL fall through to the next entry in the role's
ordered `families[]` and disclose the substitution. After a family and model
have resolved, the absence of a model at the next tier SHALL make vertical
escalation unavailable for that family; it SHALL NOT change the resolved tier
or family and SHALL NOT fail the otherwise valid resolution.

#### Scenario: Two models claim the same family-tier default

- **WHEN** two models in one family and tier are both marked `default`
- **THEN** registry validation fails as ambiguous

#### Scenario: Several models declare no family-tier default

- **WHEN** one family has multiple models at a tier and none carries `default: true`
- **THEN** registry validation fails rather than selecting by order or inventory accident

#### Scenario: A family-tier rung has one model

- **WHEN** a family has exactly one model at a tier and that model omits `default`
- **THEN** registry validation accepts the rung and resolution selects its sole model

#### Scenario: A compatible family has no model at the resolved rung

- **WHEN** the first `families[]` entry has a compatible harness but no model at the resolved tier
- **THEN** role resolution treats that family as unavailable, tries the next family, and discloses the substitution without changing the resolved tier

#### Scenario: A resolved family has no model on the next escalation rung

- **WHEN** vertical escalation is requested but the resolved family has no model at the next tier
- **THEN** escalation is unavailable for that family and resolution keeps its current family and tier without failing

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

### Requirement: Execution-control labels require attributable provenance

Before any `tier:*`, `strategy:*`, or `rigor:*` label changes execution, an
interactive session SHALL obtain attributable operator confirmation for every
off-default resolution. An unattended consumer SHALL re-read its trusted-actor
configuration immediately before acting and verify the label's provenance end to
end. If provenance is absent, stale, or untrusted, the consumer SHALL use the
configured defaults and emit a warning. A consumer SHALL NOT apply an execution-
control label to authorize its own run.

#### Scenario: An interactive label requests an off-default tier

- **WHEN** an interactive run resolves a tier label above or below its configured default without operator confirmation in the current session
- **THEN** the off-default resolution remains unauthorized and no dispatch uses it

#### Scenario: An unattended label has untrusted provenance

- **WHEN** an unattended consumer cannot prove a control label came from an actor in its freshly re-read trusted-actor configuration
- **THEN** it warns, falls back to configured defaults, and does not act on the label
