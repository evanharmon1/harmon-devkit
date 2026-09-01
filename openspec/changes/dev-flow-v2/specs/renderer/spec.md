## Purpose

Defines deterministic projections from validated Dev flow records so human
Markdown, thread actions, readiness inputs, and machine evidence cannot drift
from independently authored summaries.

## ADDED Requirements

### Requirement: One adjudication record owns every projection

The orchestrator-authored adjudication record SHALL be the source for deferred
finding items, per-round tables, PR-body adjudication rows, disposition tokens,
and thread-reply plans. Renderers SHALL NOT infer final dispositions from raw
reviewer labels or re-author the same decision separately on each surface.

#### Scenario: Reviewer and orchestrator priorities differ

- **WHEN** a reviewer labels a finding P1 and the adjudication record assigns P2 with evidence
- **THEN** rendered gating and disposition surfaces use P2 while preserving the reviewer label for comparison

### Requirement: Required projections are deterministic

The renderer SHALL produce byte-stable deferred-findings, adjudication-record,
round-table, resolved-policy disclosure, blocker-comment, and thread-reply-plan
projections from identical ordered input. Golden fixtures SHALL cover every
projection and disposition.

#### Scenario: The same record is rendered twice

- **WHEN** no input bytes or rendering version changed
- **THEN** every output projection is byte-identical

### Requirement: Deferred findings use validated settlement grammar

Every deferred P2 SHALL render exactly once with its finding identity, location,
summary, and an unchecked state until integration appends one terminal
settlement: fix, decline, or file. Readiness evaluation SHALL consume the
validated JSON and settlement records rather than parse the rendered Markdown.

#### Scenario: A deferred finding is settled by follow-up issue

- **WHEN** integration appends a `file` settlement with an issue identifier
- **THEN** the PR projection becomes checked with that issue reference and the readiness input reports the finding settled

### Requirement: Multi-surface dispositions remain equivalent

A rendered inline reply plan SHALL retain the root comment linkage and the same
finding identity, priority, classification, evidence, action, and affected head
as the ledger and PR-body projections. Verification SHALL compare their
semantic source record, not merely confirm that three writes succeeded.

#### Scenario: A reply targets the wrong thread root

- **WHEN** a generated reply plan's root ID differs from the adjudication record
- **THEN** projection validation fails before any reply is posted

### Requirement: Remote handoff is idempotent and interruption-safe

Publication SHALL validate local sidecar entries against adjudications, require
the exact pushed head and a draft PR, and capture the remote body version before
writing, using `updatedAt`, an ETag, or an exact full-body snapshot. It SHALL
re-read the latest body, re-merge generated sections into that version while
preserving every non-generated section, and compare-and-write against the
captured version. A concurrent mutation between read and write SHALL restart the
merge from a fresh read. Publication SHALL re-read and fingerprint the result and
SHALL NOT retire local source records until the remote body matches the version
and merged content it intended. An indeterminate or partial write SHALL be safe
to retry without duplicating entries.

#### Scenario: Interruption follows the PR-body write

- **WHEN** the session stops after updating the body but before recording success locally
- **THEN** a resumed handoff adopts the matching remote projection and does not create a duplicate section

#### Scenario: A human edits the PR body during generated-section upsert

- **WHEN** the remote body version changes after publication's initial read and before its write
- **THEN** publication retries from the new body, preserves the human edit, and re-merges only its generated sections

### Requirement: Blocker reports bind to unresolved state

Blocker projections SHALL identify the affected head, stage, outcome, unresolved
conditions or findings, spent limits, and the attributable next action. A head
change SHALL invalidate a blocker or readiness projection that claims a prior
head.

#### Scenario: Integration caps on an unreviewed fix head

- **WHEN** the final allowed cycle finds an issue and the resulting fix moves the head beyond the cycle cap
- **THEN** the blocker projection names the new unreviewed head and leaves the PR draft
