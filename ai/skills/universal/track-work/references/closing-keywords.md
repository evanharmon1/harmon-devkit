# Closing keywords

`Closes`, `Fixes`, `Resolves` (and their `-s`/`-d` inflections) in a PR body are
an instruction to GitHub: **close this issue when the PR merges**. GitHub obeys
it exactly. That is the whole failure mode — nothing malfunctions, the design is
just wrong.

## The rule

| Situation | Keyword |
| --- | --- |
| The PR resolves the issue **entirely** | `Closes #N` |
| The PR does part of it | `Refs #N` |
| The issue has unticked items the PR won't tick | `Refs #N` |
| The issue is in another repository | `Refs owner/repo#N` — never a closing keyword |
| You are not sure | `Refs #N` |

`Refs` links the PR to the issue in the timeline and closes nothing. It is the
default; a closing keyword is the exception you justify.

## The check

```sh
<skill-dir>/assets/check-closing-keywords.sh --repo <owner/repo> <body-file>
```

Exit 0 safe, 1 violation, 2 could not verify — and *could not verify* is not
*clean*. In a repo that wires it up, `task guard:closing-keywords` runs the same
check from `$PR_BODY`, and CI runs it on every PR at `opened`/`edited`, so
rewording the body re-runs it.

By hand:

```sh
gh issue view <n> --repo <owner/repo> --json body --jq '.body' | grep -nE '^[[:space:]]*[-*+] \[ \]'
```

Any output means the issue holds work this PR is not finishing.

### Two deliberate over-reaches

The check is fail-closed, because missing a real closing keyword loses work
while a false positive costs one edit:

- **Code fences are scanned.** A closing keyword inside a fenced block still
  fails. If you need to *write about* one — as this file does — split the token
  (`` `closes` `` followed by `` `#329` ``) so the guard doesn't act on prose.
- **`Closes#5` counts**, even though GitHub wants a separator.

## Worked example — harmon-init#329

The clearest instance of this failing, start to finish. Every quote below is
from the live issue and PR.

**The setup.** `harmon-init/docs/sourceRepoFollowUps.md` was a follow-up doc that
had gone untouched for months. An audit before deleting it found 14 items: 10
genuinely done, 1 obsolete, and 3 still open. The finding was recorded as
issue #329, titled — accurately —
*"Delete orphaned docs/sourceRepoFollowUps.md (3 items still open)"*.

The issue body listed the survivors as task-list items:

```markdown
## But 3 of its 14 items are still open

- [ ] **sommerlawn-site: `links-online.yml` pinned to `arduino/setup-task@b91d5d2c` (v2.0.0).**
- [ ] **harmon-infra: `validate.yml:51` reinstalls lint tools inline** …
- [ ] **sommerlawn-site: `sommer-lawn` naming residue.** …
```

and closed with an explicit instruction to whoever picked it up:

> They live in other repos — either fix them during the next standardization
> sweep of sommerlawn-site / harmon-infra, or split them into per-repo issues.
> Delete `docs/sourceRepoFollowUps.md` **once they are recorded somewhere
> durable.**

**The mistake.** PR #335 deleted the file. Its body opened:

> Final batch from #328, and `closes` `#329`.

**The result.** #335 merged on 2026-07-21. GitHub closed #329 as *completed*.
The three items are still unticked inside it today — in a closed issue, on
nobody's backlog, in **harmon-init**, which owns none of the work. Two belong to
sommerlawn-site and one to harmon-infra.

The commit message asserted that the file's deletion "loses nothing" because the
items were recorded in #329. That sentence was true when written and false the
moment the PR merged.

**What the check would have done.** #329's body has three `- [ ]` lines, so
`check-closing-keywords.sh` exits 1 on that body and names them.

**What should have happened**, in order:

1. File three issues — two in `sommerlawn-site`, one in `harmon-infra` — each
   carrying provenance back to #329.
2. Tick the three boxes in #329, now that they are recorded somewhere durable,
   which is exactly the condition the issue itself set.
3. *Then* `Closes #329` passes the check honestly, because the issue really is
   finished.

Note step 3: the check is not an obstacle to closing the issue. It is the
difference between closing it because the work is placed and closing it because
a keyword was typed.

## Why not just remember the rule

The rule was known. harmon-init's `AGENTS.md` was loaded for the entire session,
the issue's own body said "once they are recorded somewhere durable", and the
title said "3 items still open". Four separate signals, all read, all understood.
The one thing not done was running a command against the body before submitting
it — which is why this is a check and not a paragraph of advice.
