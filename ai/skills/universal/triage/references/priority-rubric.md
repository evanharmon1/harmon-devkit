# Priority rubric

Priority is the ranking of when to work an issue. It is a different question from the classification axes in
[classification-rubric.md](classification-rubric.md) (Impact, Risk, Complexity, Tier), and there are two Priority axes:
the **Priority** a human sets, and the **Priority (AI)** an agent may suggest. The human Priority always wins.

## Priority (human)

Values: `urgent` (work on this now, ahead of everything else), `high` (next up; schedule soon), `medium` (normal queue
order), `low` (when nothing more pressing remains).

- **Human-only.** An agent never sets or changes Priority.
- **Never required.** An issue counts as triaged without it. For this axis, unset means an agent asks before starting;
  it is never a gap for an agent to fill with its own ranking. Whether a Priority (AI) alone lets an issue into the
  agent queue is the queue's own rule, not this rubric's, and Priority (AI) itself arms nothing.
- **Never set by triage or backfill.** Neither the triage skill nor a bulk backfill writes it, whatever they know about
  the issue. An agent's suggestion goes in Priority (AI), below.

## Priority (AI)

Priority (AI) is the priority an agent suggests from what it knows at the time. Its values are `p0`, `p1`, `p2`, `p3`,
and `p4`. Agents and humans may write it. It is advisory, never required for an issue to count as triaged, and arms
nothing. It is stored like Priority: a `Priority (AI)` issue field on an organization repo, and a `priority-ai:<value>`
label on a personal-account repo. An agent may draw on the Impact, Risk, and Complexity it has set, but no rule derives
Priority (AI) from them, and the Tier does not read it.

### Priority (AI) anchors

| Value | Anchor |
| --- | --- |
| p0 | Blocks a merge or deploy: nothing should ship while it is open |
| p1 | A real defect or a must-do; work it next |
| p2 | Worth doing, but it does not block anything |
| p3 | Cosmetic or informational |
| p4 | Negligible: the agent judges it too small to matter |

**For a bug, Priority (AI) reads as severity:** how bad the defect is, and how important it is to fix before merging or
deploying. A defect that must not ship is `p0`; one to fix next is `p1`; one worth fixing that blocks nothing is `p2`.
Severity here is a ranking, so it is separate from Impact (the harm the fix prevents) and from Risk (the danger of the
fix).

### The human Priority overrides it

The **effective priority** of an issue is its Priority when that is set, otherwise its Priority (AI). The human Priority
wins even when it ranks the issue lower than the AI's suggestion. Priority (AI) never overwrites it, and nothing
converts one into the other. **An agent never writes the human Priority;** an agent that suggests a priority writes
Priority (AI) only, and leaves the human field and label family alone. Triage *suggesting* a Priority (AI) is the
triage skill's own contract; this rubric defines what the values mean.

### Review findings carry their badge

When a review finding (a cloud reviewer, or a local challenge or review round) is filed as an issue, the new issue is
created with Priority (AI) set from the finding's **adjudicated** severity, not the reviewer's label: P0 → `p0`,
P1 → `p1`, P2 → `p2`, P3 → `p3`. **Nothing from a review maps to `p4`**; `p4` is for work an agent judges negligible
outside a review. The capital letters are review severities and the lowercase values are this axis, so keep the two
spellings apart.

### Priority (AI) worked examples

- **Feature: "Add a `--dry-run` flag to the deploy script, so next week's cutover can be rehearsed."** The cutover
  itself does not need it, but the rehearsal planned for it does, so committed work waits on it: a must-do, next:
  **`p1`**. Nothing is blocked from merging or deploying without it, which rules out `p0`. If the maintainer then sets
  Priority to `medium`, the effective priority is `medium`; Priority (AI) stays `p1`, untouched, and no agent edits the
  human field.
- **Bug: "Session tokens are written to the log in plaintext by the debug middleware, and the middleware is enabled in
  production."** It is a security exposure that must not ship or stay deployed, so read it as severity: **`p0`**. The
  harm it prevents is also a high Impact and the fix is probably a low Risk, but those are separate scores and neither
  one sets the priority.
