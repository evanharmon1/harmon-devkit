# Closing keywords

`Closes`, `Fixes`, `Resolves` (and their `-s`/`-d` inflections) in a PR body are
an instruction to GitHub: **close this issue when the PR merges**. GitHub obeys
it exactly. That is the whole failure mode — nothing malfunctions, the design is
just wrong.

The **PR title and the commit messages carry the same instruction.** GitHub
honours closing keywords in commit messages that land on the default branch, and
a squash-merge repo puts the PR title in the commit subject. Worse, a repo whose
`squash_merge_commit_message` is `COMMIT_MESSAGES` (harmon-devkit's is) copies
every commit message into the squash commit's body — so a keyword buried in the
third commit of a PR reaches `main` even though the PR body is spotless.

Check all three. A title reading `fix: tidy up, closes #123` is as final as a
body, and much easier to miss.

## The rule

| Situation | Keyword | Where to write it |
| --- | --- | --- |
| The PR resolves the issue **entirely** | `Closes #N` | anywhere |
| The PR does part of it | `Refs #N` | **PR body only** |
| The issue has unticked items the PR won't tick | `Refs #N` | **PR body only** |
| The issue is in another repository | `Refs owner/repo#N` — never a closing keyword | PR body only |
| You are not sure | `Refs #N` | **PR body only** |

`Refs` links the PR to the issue in the timeline and, *to GitHub*, closes
nothing. It is the default; a closing keyword is the exception you justify.

**The third column is load-bearing and is not a style preference.** Where a
changelog is generated from commits, a reference sitting in the commit's footer
is harvested and re-rendered under a hardcoded `closes` list — the generator
never reads the keyword, so `Refs` is converted like any other. That has
already closed an issue in this repo with none of its criteria ticked. Whether
it fires depends on how many commits the PR ends up with, which you cannot know
while writing. Keeping the bare `#N` in the PR body and out of the commit
removes the only step you control from the chain. The skill's §2 has the
evidence and the mechanism.

## The check

```sh
git log --format=%B <base>..HEAD >/tmp/commits.txt
PR_TITLE="<title>" PR_BODY="<body>" \
  <skill-dir>/assets/check-closing-keywords.sh --repo <owner/repo> \
    --title-env PR_TITLE --body-env PR_BODY --commits-file /tmp/commits.txt
```

Exit 0 safe, 1 violation, 2 could not verify — and *could not verify* is not
*clean*. In a repo that wires it up, `task guard:closing-keywords` runs the same
check, and CI runs it on every PR at `opened`/`edited`.

**Clearing a red check.** Editing the PR title or body re-runs it automatically.
Ticking the issue's boxes does **not** — the workflow watches pull-request
events, not issues, so that path needs the check re-run by hand.

By hand:

```sh
gh issue view <n> --repo <owner/repo> --json body --jq '.body' | grep -nE '^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+\[[[:space:]]\]'
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
- [ ] **platform-infra: `validate.yml:51` reinstalls lint tools inline** …
- [ ] **sommerlawn-site: `sommer-lawn` naming residue.** …
```

and closed with an explicit instruction to whoever picked it up:

> They live in other repos — either fix them during the next standardization
> sweep of sommerlawn-site / platform-infra, or split them into per-repo issues.
> Delete `docs/sourceRepoFollowUps.md` **once they are recorded somewhere
> durable.**

**The mistake.** PR #335 deleted the file. Its body opened:

> Final batch from #328, and `closes` `#329`.

**The result.** #335 merged on 2026-07-21. GitHub closed #329 as *completed*.
The three items are still unticked inside it today — in a closed issue, on
nobody's backlog, in **harmon-init**, which owns none of the work. Two belong to
sommerlawn-site and one to platform-infra.

The commit message asserted that the file's deletion "loses nothing" because the
items were recorded in #329. That sentence was true when written and false the
moment the PR merged.

**What the check would have done.** #329's body has three `- [ ]` lines, so
`check-closing-keywords.sh` exits 1 on that body and names them.

**What should have happened**, in order:

1. File three issues — two in `sommerlawn-site`, one in `platform-infra` — each
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
