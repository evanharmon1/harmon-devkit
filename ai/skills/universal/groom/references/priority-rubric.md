# Priority rubric

Used for every disposition row's `priority` field and for the report's
priority mix and ranking. Subagents can emit either the standard
tiers (`p0`, `p1`, `p2`, `p3`) or the legacy aliases (`urgent`, `high`, `medium`, `low`).

| Priority | Alias | When |
| --- | --- | --- |
| `p0` | `urgent` | Critical security vulnerability, active production outage, or blocking all other work. |
| `p1` | `high` | Security-relevant, breaks something a consumer relies on today, or unlocks other blocked work (a `NEEDS-DECISION` that other issues are `blocked-by`). |
| `p2` | `medium` | A real defect or feature with no urgent trigger; most of the backlog lands here. |
| `p3` | `low` | Cosmetic, speculative, or a nice-to-have with no forcing function. |

A `NEEDS-DECISION` row that unblocks other issues (check the target repo's
`blocked-by` edges, or the issue's own body for `Blocked by: #N` lines
pointing at it) is `high` / `p1` (or `p0` if blocking the entire project)
regardless of how the underlying work would otherwise rate — the cost of leaving
it undecided compounds across every issue waiting on it.

**Priority is reported only, never written to the board.** The dataset and
report always carry every row's computed priority — that IS the delivery
mechanism today. Writing it to the project board's own Priority field is
**deliberately not started**: no `groom-apply.sh` plan op reaches
`track-work`'s `set-issue-status.sh`-style board write path (the plan
vocabulary is close/retitle/label/milestone-assign/sub-issue-link — there is
no priority op), and `groom-scan.sh`'s `board_access` field is informational
only, not a gate on a write path that does not exist yet. Name "board
Priority write" under the run's "deliberately not started" list (SKILL.md
Step 7) until a plan op for it is introduced.
