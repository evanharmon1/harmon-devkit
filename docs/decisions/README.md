# Decisions (ADRs)

Append-only records of why each choice was made — they stop an agent from
"helpfully" undoing a deliberate choice, and justify **deviations from best
practice**.

Each record captures one choice: its context, the decision, and the **explicit
"not" reasoning** (what was rejected and why). **Supersede, don't edit:** to
change a decision, add a new ADR that supersedes the old one and mark the old
one's status.

- One ADR per file, named `YYYY-MM-DD-<kebab-title>.md` — the date the
  record was filed, fixed at creation and never changed by a later status
  change (a `Proposed` record keeps its filing date when accepted; the
  `Status` line carries the outcome). Records from before this convention
  keep their numbered `NNNN-` names; both forms are valid. The one
  exception is the seed record below: the project template maintains it,
  so a template update re-titles a numbered seed to the date form.
- Start with
  [2026-06-19-record-architecture-decisions.md](2026-06-19-record-architecture-decisions.md)
  — the meta-ADR for the process. The project template maintains it: its
  name and `Date:` come from the `decisions_seed_date` answer recorded when
  the repository was scaffolded (or when an update first introduced the
  date form), so updates keep improving its content without renaming it.
  Copy it as the starting point for new ADRs — the copy is an ordinary
  record and nothing in its body is seed-specific.
- [0008-versioned-devflow-compatibility-contract.md](0008-versioned-devflow-compatibility-contract.md)
  — proposed v1 contract for portable devflow consumers.
