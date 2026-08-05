# Follow-up work across repos

The rule: **work belonging to another repo is filed in that repo, immediately,
with provenance.** Not batched, not deferred to the end of the session, not
written down somewhere central.

This is not a preference. Both alternatives have been tried here and both
failed, in opposite directions.

## Why the two obvious alternatives don't work

### A follow-up doc — durable, invisible

`harmon-init/docs/sourceRepoFollowUps.md` collected cross-repo follow-ups in one
tracked markdown file. It survived every sweep — byte-identical from v3.26.1 to
v4.2.1 — which is exactly the problem. Nothing was lost and nothing was read.

When it was finally audited, **10 of its 14 items had silently been completed**
by unrelated work, and one more had gone obsolete. The doc had spent months
describing a world that no longer existed, in a repo where none of the work
lived. A file in the wrong repo is a file nobody greps.

### A tracking issue — visible, but mortal

The replacement was harmon-init#329: same items, but an issue, so it would show
up on a backlog. It did — until a PR wrote a closing keyword at it and the merge
closed it with three items still unticked. See
[`closing-keywords.md`](closing-keywords.md).

Durable but invisible, then visible but mortal. **An issue in the repo that owns
the code is the only option that is both** — it survives, and it appears in front
of the person who would actually fix it, in the tracker they actually read.

## Look there before you file there

The search that finds a duplicate has to run against **the repo you are filing
into**. Nothing about the working session points there: the checkout, the greps,
`gh`'s default repo, and every earlier `gh issue list` are all bound to the repo
you are *in*, so the habitual duplicate check answers a question nobody asked.

```sh
gh issue list --repo <target-owner/target-repo> --state all --limit 200 \
  --search "<distinctive phrase from the invariant>"
```

`--state all` surfaces a previous `not planned` — a decision to engage, not a
gap to fill. `--limit 200` because the default returns one page
([`gh-verification.md`](gh-verification.md)). Query the invariant's
words rather than your title's; the same defect is named differently by everyone
who finds it.

**This has already cost something here.** While doing harmon-devkit#180 an agent
filed harmon-init#460 after searching harmon-devkit — the repo it was working in
— and finding nothing. harmon-init#412 had been open the whole time. The
duplicate was the cheap half of the damage: #412 recorded that the ignore rule
came from harmon-init#375 *because* a tracked lockfile had gone stale, so filing
blind also meant recommending a fix that reversed a deliberate earlier decision.
A duplicate wastes triage; a duplicate that contradicts the original is worse.

**On a hit, read the issue — then act on what state it is in.** For an open
issue, add your evidence as a comment there: it already holds the context, and a
second issue with half the reasoning is worse than a comment with all of it. But
"comment on it" is not the answer for every hit, and a closed `completed` issue
whose defect has come back needs a *live* issue rather than a footnote on a
settled one. The three cases are tabulated in the skill's §3 — follow that table
rather than the one-line version, and do not reason about it from here.

**If a duplicate lands anyway**, move the evidence before closing: comment
whatever the canonical issue lacks onto it, *then* close yours with
`--reason duplicate` **and a comment naming the canonical issue**. Both halves
matter. Closing first strands the new evidence in an issue nobody will open
again; closing without naming the target strands the pointer, because GitHub
stores the reason and not what it duplicates (skill §3). And `not planned` is the
wrong reason here — it makes the next duplicate search read this issue as a
declined decision rather than a pointer, and send the finding down the wrong
branch of §3's table.

## Filing it

Three commands, at the moment you find the work — not later. The search above is
the first:

```sh
gh issue create --repo <target-owner/target-repo> \
  --title "<what needs to change>" \
  --body-file -
```

Use a quoted heredoc so nothing in the body is re-evaluated by the shell:

```sh
gh issue create --repo evanharmon1/harmon-infra --title "…" --body-file - <<'EOF'
<the invariant, the observed violation with a date, and a Verify command>

---
Found while doing evanharmon1/harmon-init#329 — filed here because this repo
owns `.github/workflows/validate.yml`.
EOF
```

Then link back from where you found it, so the trail runs both ways:

```sh
gh issue comment <n> --repo <origin-owner/origin-repo> \
  --body "Split out: <target-owner/target-repo>#<new>"
```

Both are writes — get the user's explicit go-ahead before running them.

## Provenance

One line, at the bottom of the body:

```text
Found while doing <owner/repo>#<n> — filed here because this repo owns <thing>.
```

It costs a sentence and it answers the question every relocated issue provokes
six months later: *why is this here, and what was the person doing when they
noticed?* Without it, a reader can't tell a considered split from a misfile.

## Getting the repo right

- A bare `#123` always means the current repo. The moment a number crosses a
  repo boundary it must be written `owner/repo#123` or as a full URL — in issue
  bodies, in comments, in commit messages, and in anything you say to the user.
- Verify it the same way: `gh issue view 123 --repo owner/repo`. A bare number
  checked against the wrong repo will happily return a real, unrelated issue.
- Which repo owns a thing is a question about where the code lives, not where
  the conversation is happening.

## The one-line test

**You are about to write "we should also…" about code in another repo.** If
there is no issue number in *that* repo to point at, the thought is about to be
lost. File it first.
