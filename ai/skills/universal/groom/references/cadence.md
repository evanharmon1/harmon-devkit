# Cadence guidance

Run `/groom` (audit mode) when any of these hold:

- It has been about a month since the last run.
- Open-issue count crosses a threshold that makes the backlog hard to scan
  (a few hundred, on the harmon-init-scale run this skill is modeled on).
- A `triage` rolling report keeps re-reporting the same aging or
  possible-completion candidates — that is exactly the signal `triage` cannot
  act on and `groom` exists to close.

## Sizing (from the 2026-09-13 harmon-init reference run)

- ~384 open issues, split into 50–70-issue clusters (~6 clusters).
- Each cluster subagent spent roughly 160k–240k tokens on the audit
  (read-only: `gh issue view`, `gh pr list`/`gh pr view` for evidence, and the
  live tree).
- The apply phase that followed was ~200 individual writes (closes, pointer
  comments, milestone/parent edits, decision comments).

A first run on an unusually large or old backlog costs more than a steady-state
monthly run, because more of the audit's findings are genuinely new. Budget
accordingly and prefer the smaller cluster size (50, not 70) the first time.

## After a run

Recommend a `/triage` run next (issue #1015: the two stay separate — triage
classifies, groom decides what the tracker should contain). Groom's apply
phase changes labels, milestones, and structure; triage's classification pass
is the routine way to re-settle the taxonomy afterward.
