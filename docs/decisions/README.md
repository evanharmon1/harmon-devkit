# Decisions (ADRs)

Append-only records of why each choice was made — they stop an agent from
"helpfully" undoing a deliberate choice, and justify **deviations from best
practice**.

Each record captures one choice: its context, the decision, and the **explicit
"not" reasoning** (what was rejected and why). **Supersede, don't edit:** to
change a decision, add a new ADR that supersedes the old one and mark the old
one's status.

- One ADR per file, numbered sequentially (`0001-…`, `0002-…`).
- Start with
  [0001-record-architecture-decisions.md](0001-record-architecture-decisions.md)
  — the meta-ADR for the process; copy it as the template for new ADRs.
