# Writing and closing issues

## Isolate the part that rots

An issue is read once when it is written and again, possibly months later, when
someone picks it up. Everything in it falls into one of two categories, and they
age very differently:

- **The invariant** — what must be true. Does not rot.
- **The observation** — `file:line`, "currently does X", a quoted snippet. Rots,
  sometimes within a day, and a merged PR from the same session is enough.

The instinct is to strip the observations. Don't — you usually need the line
number to find the thing. **Isolate them and ship the command that re-checks
them:**

```markdown
## Invariant
<what must be true — does not rot>

## Current violation (observed YYYY-MM-DD)
<file:line, behaviour — perishable; a lead, not a fact>

## Verify
<a command that re-establishes whether this still holds, and what its output
means>
```

The `Verify` block is the whole point. With it, a reader confirms in seconds
whether the observation is still live. Without it, a stale citation and a live
one look identical — and the reader either wastes an afternoon or, worse,
believes it.

```sh
<skill-dir>/assets/check-issue-rot.sh <draft-file>
```

Exit 1 means the draft cites something perishable with no way to re-check it.
Add the section before filing.

### A real one, before and after

harmon-init#327 opens with an observation that is precise, useful, and entirely
unverifiable by a reader:

> **The aggregate is fail-open.**
> `template/.github/workflows/…terraform.yml.jinja:119` —
> `[ "$2" = "success" ] || [ "$2" = "skipped" ] || { … fail=1; }`. A
> silently-skipped `terraform-validate` reports green.

The issue is still open. To act on it you must first go and find out whether
line 119 still says that — and if the file has been touched since, you cannot
tell whether the problem was fixed or merely moved. Restructured:

````markdown
## Invariant
The terraform CI aggregate must not accept `skipped` as success. A job that
never ran is not a job that passed.

## Current violation (observed 2026-07-20)
`template/.github/workflows/…terraform.yml.jinja:119` treats `skipped` as a pass,
so a silently-skipped `terraform-validate` reports green.

## Verify
```sh
grep -n 'skipped' template/.github/workflows/*terraform.yml*.jinja
```

Any hit inside the result aggregation means the violation is still live.
````

Same information. The difference is that the second one tells you, in one
command, whether it is still worth your time.

## The strongest form: ship a failing assertion

Where the repo has a test harness, an issue can carry an **assertion that fails
today** instead of a description of what's wrong. It cannot rot, because the
codebase evaluates it rather than the reader, and it closes when the test passes.

The example above is a candidate: *"the aggregate must reject `skipped`"* is
directly expressible as a case in harmon-init's `test-template.sh` that fails
against `main` right now. An issue built that way is finished when CI says so.

Reach for this whenever the invariant is mechanically checkable. Fall back to
Invariant/Violation/Verify when it isn't.

## Acceptance criteria

Write them as task-list items:

```markdown
## Acceptance criteria

- [ ] The aggregate fails when any required job is `skipped`
- [ ] A regression test covers the skipped case
```

Two reasons, beyond legibility:

- They are what `check-closing-keywords.sh` reads. An issue with no task list
  gives the closing-keyword guard nothing to protect, so the protection silently
  does not apply.
- Ticking them is how "is this done?" gets answered without re-litigating the
  whole issue.

Keep them to things a reader can adjudicate. "Works well" is not a criterion.

## Close reasons

`completed` and `not planned` are different factual claims.

```sh
gh issue close <n> --repo <owner/repo> --reason completed
gh issue close <n> --repo <owner/repo> --reason "not planned" --comment "Superseded by …"
gh issue close <n> --repo <owner/repo> --reason duplicate --comment "Duplicate of owner/repo#<n>"
```

| Reason | Means |
| --- | --- |
| `completed` | It was built. Every acceptance item is ticked. |
| `not planned` | It won't be built — declined, obsolete, **or superseded** |
| `duplicate` | It *will* be done, tracked elsewhere. Name that issue in the comment — GitHub stores the reason, not the target. |

`duplicate` is a reason in its own right, not a flavour of `not planned`: the
work is live somewhere else rather than declined, and a later duplicate search
reads `stateReason` and branches on exactly that difference (skill §3).

**Superseded work closes `not planned`, with a comment naming what replaced
it.** This is the case most often got wrong, because the work "went away" and
that feels like completion. It isn't: nobody built the thing, so `completed` is
false, and the next person to find the issue learns nothing about why it stopped
mattering.

harmon-devkit#113 is the pattern done right —
*"standardize-repo: verify-applied.sh enforces a Terraform contract harmon-init
does not generate"*. The issue was never wrong. harmon-init#327 reframed the
problem such that #113 no longer needed doing, so it was closed **not planned**,
not completed. The record now says what actually happened.

**Fail condition:** closing with `completed` while `gh issue view <n> --json
body` still shows `- [ ]`.

## Before filing, quickly

- **Right repo** — the one that owns the code, not the one you happen to be in.
  See [`cross-repo-work.md`](cross-repo-work.md).
- **Perishable claims covered** — `check-issue-rot.sh` exits 0.
- **Acceptance criteria as `- [ ]`.**
- **Provenance**, if the work was found somewhere else.
- **Search first, in the repo from the previous bullet** — not the one you are
  working in:

  ```sh
  gh issue list --repo <target-owner/target-repo> --state all --limit 200 \
    --search '<distinctive phrase>'
  ```

  A duplicate is rarely linked from anywhere, so nothing surfaces it but this
  command. `--state all` and `--limit 200` are both load-bearing. On a hit, read
  that issue and then act on **what state it is in** — commenting is right for an
  open one, while a closed `completed` issue whose defect recurred needs a live
  issue instead. The skill's §3 tabulates all three cases; follow it there, and
  see [`cross-repo-work.md`](cross-repo-work.md) for the recovery when a
  duplicate lands anyway.
