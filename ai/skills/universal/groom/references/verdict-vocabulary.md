# Verdict vocabulary

Every fan-out subagent writes one JSON object per line (JSON Lines), one line
per issue it verified. `groom-verdicts.sh` enforces this contract; the fields
below are exactly what it checks.

## Required fields

| Field | Type | Notes |
| --- | --- | --- |
| `number` | integer | the issue number |
| `verdict` | string | exactly one value from the vocabulary below |
| `priority` | string | `high`, `medium`, or `low` |
| `reason` | string | one line, nonempty |
| `evidence` | string | required nonempty for every `CLOSE-*` verdict; empty is fine for `KEEP`/`NEEDS-INFO` |
| `group` | string | the proposed cluster/area grouping |

## Conditional field

| Field | Required when | Notes |
| --- | --- | --- |
| `question` | `verdict == "NEEDS-DECISION"` | one sentence, phrased so the maintainer can answer it directly |

## The verdicts

- `CLOSE-done` — the work shipped. Evidence: a merged PR, a file that now
  exists, or a removed feature.
- `CLOSE-obsolete` — the need it described no longer exists.
- `CLOSE-dup-of-#N` — a literal duplicate of open issue `#N` in the same
  repository. Evidence should still name what makes it a duplicate.
- `CLOSE-wrong-repo (target)` — belongs in a different repository. `target`
  is a description of where it belongs (a repo slug when known).
- `KEEP` — stays open, no action needed this run.
- `NEEDS-DECISION` — a maintainer must choose between real options. Carries
  `question`.
- `NEEDS-INFO` — cannot be verified without more information from the author
  or a live system this run cannot reach.

## The rule that makes it safe

**A `CLOSE-*` verdict needs concrete evidence** — a merged PR, a file that now
exists, a feature that was removed, or (for a duplicate) the issue number and
what makes it the same. A comment claiming "done" is never evidence on its
own. **When unsure, `KEEP` with a note** in `reason` — a wrong `KEEP` costs one
more look next run; a wrong `CLOSE` deletes tracked work from the backlog.

Never verify from memory. Read the live code and the merged PR, not a
description of either.
