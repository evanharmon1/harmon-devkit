# Spec: Registry-driven labels in breakdown

- **Status:** Implemented
- **Owner:** evanharmon1
- **Date:** 2026-08-17
- **Related:** [harmon-devkit#451](https://github.com/evanharmon1/harmon-devkit/issues/451), [harmon-devkit#333](https://github.com/evanharmon1/harmon-devkit/issues/333), [harmon-init ADR 0006](https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/0006-method-and-tier-axes.md)

## Problem / Why

The `breakdown` skill currently reads the target repository's live GitHub
labels and describes selected label families directly in Markdown. That does
not use the machine-readable `label-registry.json` contract recently added to
Harmon repositories, so the skill can drift from repository-specific values,
writer permissions, lifecycle rules, exclusivity, and arming semantics.

Encoding registry interpretation as increasingly detailed prose would create a
second, untested implementation of the label model. The behavior should instead
be registry-driven and implemented in a tested script where it becomes
algorithmic.

## Goal

Make `breakdown` derive planning-safe label proposals from each target
repository's own label registry, without embedding repository-specific label
values in the skill, minting labels, or applying lifecycle and arming labels.
Repositories without a registry retain a conservative live-label fallback.

## Non-goals

- Creating, provisioning, renaming, or deleting labels.
- Changing `triage` ownership of backlog classification.
- Applying claim markers, assignees, project `Status`, or Foreman arming labels.
- Closing harmon-devkit#333 unless its separate acceptance criterion is
  deliberately implemented, verified, and tracked.
- Executing scripts or other code obtained from the target repository.

## Requirements

- [x] Read `label-registry.json` from the target repository's current default
  branch when it exists; do not substitute the working checkout's potentially
  stale or unrelated copy.
- [x] Treat registry metadata as the vocabulary contract, including `prefix`,
  `purpose`, `writers`, `lifecycle`, `source`, `exclusive`, `arming`,
  `provision`, `retired`, `open_values`, and per-value overrides.
- [x] Derive planning-safe candidates from metadata rather than a hardcoded
  roster: the effective writer permits agents, the effective lifecycle is
  durable, and the family/value is neither retired nor arming.
- [x] Interpret `inline`, `agent-registry`, and `tool-owned` sources without
  executing target-repository code.
- [x] Intersect concrete proposals with the target's live GitHub label
  inventory. Never mint a missing label, including an open or tool-owned value.
- [x] Use the registry's `suggest` semantics for advisory routing and its
  `suggest-model` semantics for family-plus-model pairing. Suggestions never arm
  execution.
- [x] Use the registry's `area` values and exclusivity metadata rather than
  embedding values such as `area:ci` in `SKILL.md`.
- [x] Exclude claim ownership, transient/tool-managed lifecycle state,
  assignees, `In Progress`, and arming labels from breakdown writes.
- [x] Fall back to `gh label list` conservatively when the target has no label
  registry, preserving the never-mint and non-arming boundaries.
- [x] Fail with a clear diagnostic when a present registry is malformed,
  ambiguous, or cannot be interpreted safely; do not silently treat it as
  absent.
- [x] Prefer a small, tested script or asset for registry discovery, filtering,
  live-label intersection, and diagnostics whenever those operations would
  otherwise require complex Markdown instructions. Keep `SKILL.md` focused on
  policy, sequencing, and invoking the asset.

## Acceptance criteria (Given / When / Then)

### Scenario: Registry-driven planning labels

- **Given** a target repository with a valid `label-registry.json`
- **When** `breakdown` prepares label proposals
- **Then** its candidates and semantics come from that registry rather than an
  embedded label-value roster
- **And** only planning-safe labels that also exist in the live GitHub inventory
  are proposed

### Scenario: Repository-specific area vocabulary

- **Given** two target repositories whose registries define different `area`
  values
- **When** equivalent work is broken down in each repository
- **Then** each proposal uses only the corresponding repository's area
  vocabulary and exclusivity rule

### Scenario: Advisory model suggestion

- **Given** registry families for family-level and model-level suggestions
- **When** a model-level suggestion is appropriate and its concrete label
  already exists
- **Then** the family suggestion is proposed alongside the model refinement
- **And** neither label is treated as an execution trigger or claim

### Scenario: Missing registry fallback

- **Given** a target repository without `label-registry.json`
- **When** `breakdown` discovers its vocabulary
- **Then** it uses the bounded live GitHub label listing conservatively
- **And** it does not mint labels or infer unsafe lifecycle behavior

### Scenario: Invalid registry fails closed

- **Given** a target repository where `label-registry.json` exists but is
  malformed or internally ambiguous
- **When** label discovery runs
- **Then** it returns a diagnostic and no label proposal is treated as verified
- **And** it does not fall back as though the registry were absent

### Scenario: Lifecycle exclusions

- **Given** a registry containing claim, tool-managed, transient, and arming
  families alongside durable planning labels
- **When** planning-safe candidates are derived
- **Then** only durable, agent-writable, non-retired, non-arming candidates are
  eligible

## Implementation plan

1. Establish session coordination, then create a feature worktree and branch
   from current `main` with `task worktree:new`. This implementation skipped
   the issue claim at the maintainer's explicit direction during a GitHub
   outage.
2. Design a narrow `breakdown` asset interface that accepts a target repository
   and emits the verified planning vocabulary or a typed diagnostic. Reuse
   existing registry render/validation behavior where it is safely callable;
   do not duplicate its rules in prose.
3. Implement registry-first discovery and filtering in the asset, including
   live-label intersection and a distinct no-registry fallback path.
4. Update `ai/skills/universal/breakdown/SKILL.md` to state policy and invoke the
   asset, removing transition-era `Agent`-field guidance that conflicts with the
   registry contract.
5. Add hermetic tests covering registry-first discovery, repository-specific
   values, source kinds, per-value overrides, model-family pairing, missing
   registry fallback, malformed-registry failure, never-mint behavior, and
   lifecycle/arming exclusions.
6. Run `task test:skills`, `task check`, and `task verify`. Reconfirm that
   harmon-init ADR 0006 satisfies the sequencing criterion before ticking
   harmon-devkit#451's verified acceptance criteria.
7. Continue through the repository's challenge, review, CI, draft-PR, and
   shepherd lifecycle. Use a `feat:` PR title because the change touches
   release content under `ai/skills`.

## Implementation decisions

- The asset consumes registry documents and live labels directly. It validates
  the supported schema subset as data and does not execute a target-owned
  renderer or validator.
- The asset owns remote retrieval so repository, default-branch, and immutable
  commit binding stay within one fail-closed boundary. Hermetic fixtures replace
  `gh` in tests.
- A family carrying `gate` is excluded unless a future contract can verify the
  corresponding target-repository opt-in. A live label alone is not proof that
  the gate remains enabled.

## Notes

- `label-registry.json` is data, not executable code. No target-owned renderer
  or validation script should be executed merely to plan labels.
- The live GitHub inventory remains necessary even with a registry: additive
  provisioning, retired values, gated families, and tool-owned open values mean
  the manifest and the currently applicable labels are related but not
  interchangeable.
- harmon-devkit#333 overlaps the same `suggest` paragraph. Its pairing invariant
  should not regress; whether to complete that issue in the same PR is a
  separate tracking decision.
