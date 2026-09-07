# Record architecture decisions

Date: 2026-06-19

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
- Named `YYYY-MM-DD-<kebab-title>.md` — the date the record was filed. The
  name is fixed at creation: a `Proposed` record keeps it when accepted or
  rejected, and the Status line carries the outcome.
- Each ADR has: Status (Proposed / Accepted / Rejected / Deprecated / Superseded), Context,
  Decision, and Consequences. Keep them short.
- ADRs are immutable once accepted; to change a decision, add a new ADR that
  supersedes the old one (and update the old one's Status).

## Consequences

- The reasoning behind decisions is preserved and discoverable.
- Reviewers and agents can read the trail instead of guessing intent.
- Copy this file as the template for the next ADR.
