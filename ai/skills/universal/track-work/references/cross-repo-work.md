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

## Filing it

Two commands, at the moment you find the work — not later:

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
