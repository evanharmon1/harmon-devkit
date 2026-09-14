# Priority rubric

Used for every disposition row's `priority` field and for the report's
high-priority count.

| Priority | When |
| --- | --- |
| `high` | Security-relevant, breaks something a consumer relies on today, or unlocks other blocked work (a `NEEDS-DECISION` that other issues are `blocked-by`). |
| `medium` | A real defect or feature with no urgent trigger; most of the backlog lands here. |
| `low` | Cosmetic, speculative, or a nice-to-have with no forcing function. |

A `NEEDS-DECISION` row that unblocks other issues (check the target repo's
`blocked-by` edges, or the issue's own body for `Blocked by: #N` lines
pointing at it) is `high` regardless of how the underlying work would
otherwise rate — the cost of leaving it undecided compounds across every
issue waiting on it.

Board Priority is written only where the run has the `project` scope
(`groom-scan.sh`'s `board_access` field says so) and only through
`track-work`'s `set-issue-status.sh`-style board write path; where the scope
is missing, note the intended priority in the report instead of guessing at a
write that would fail.
