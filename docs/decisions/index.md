# Decisions (ADRs)

Append-only records of why each choice was made — they stop an agent from
"helpfully" undoing a deliberate choice, and justify **deviations from best
practice**.

Each record captures one choice: its context, the decision, and the **explicit
"not" reasoning** (what was rejected and why). **Supersede, don't edit:** to
change an accepted decision, add a new ADR that supersedes or amends it and mark
the old one's status. Immutability applies once a record is accepted, as the
[meta-ADR](2026-06-28-record-architecture-decisions.md) says; a `Proposed`
record is still open to edits.

- One ADR per file, named `YYYY-MM-DD-<kebab-title>.md` — the date the
  record was filed, fixed at creation and never changed by a later status
  change (a `Proposed` record keeps its filing date when accepted; the
  `Status` line carries the outcome). Records filed under the older numbered
  `NNNN-` convention are renamed to the date form, dated by their own `Date:`
  line. The seed record below follows the same rule through its own
  mechanism: the project template maintains it, so a template update
  re-titles a numbered seed to the date form.
- Start with
  [2026-06-28-record-architecture-decisions.md](2026-06-28-record-architecture-decisions.md)
  — the meta-ADR for the process (Accepted). The project template maintains
  it: its
  name and `Date:` come from the `decisions_seed_date` answer recorded when
  the repository was scaffolded (or when an update first introduced the
  date form), so updates keep improving its content without renaming it.
  Copy it as the starting point for new ADRs — the copy is an ordinary
  record and nothing in its body is seed-specific.
- [2026-08-25-versioned-devflow-compatibility-contract.md](2026-08-25-versioned-devflow-compatibility-contract.md)
  — version the devflow compatibility contract (Accepted).
- [2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md](2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md) — PR lifecycle, live handoff check and ordered merge queue (Accepted).
