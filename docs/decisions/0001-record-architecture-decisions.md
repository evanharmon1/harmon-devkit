# 1. Record architecture decisions

Date: TODO

## Status

Accepted

## Context

We need to record the architectural decisions made on this project — the ones
that are significant, hard to reverse, or surprising to a newcomer (including an
AI agent). Without a durable record, the *why* behind a choice is lost and gets
relitigated.

## Decision

We will use Architecture Decision Records (ADRs), as
[described by Michael Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

- One ADR per decision, stored in `docs/decisions/`.
- Numbered sequentially and zero-padded: `0001-...`, `0002-...`.
- Each ADR has: Status (Proposed / Accepted / Deprecated / Superseded), Context,
  Decision, and Consequences. Keep them short.
- ADRs are immutable once accepted; to change a decision, add a new ADR that
  supersedes the old one (and update the old one's Status).

## Consequences

- The reasoning behind decisions is preserved and discoverable.
- Reviewers and agents can read the trail instead of guessing intent.
- Copy this file as the template for the next ADR.
