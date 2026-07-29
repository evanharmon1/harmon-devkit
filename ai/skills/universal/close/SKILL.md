---
name: close
description: >-
  Close-of-session ritual — check for uncommitted or unpushed work, release
  any issue claim left standing, list anything dangling, and emit the
  copy-pasteable /rename done-<session-name> command for the user. Invoke as
  /close.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(gh issue view:*), Bash(gh pr list:*)
---

# Close Session

**Arguments:** $ARGUMENTS

Wrap up the session and rename it `done-<name>` so finished sessions are easy
to distinguish in the session picker and the Claude mobile app.

## 1. Recover the session name

Look for `/orient`'s "Session name: `<name>`" line in the conversation. If it
is not in context, **ask the user** for the current session name (they can
read it in the UI) — never guess.

## 2. Wrap up

- `git status -sb` for uncommitted work; `git log @{u}..HEAD --oneline` for
  unpushed commits (guard for branches with no upstream).
- If `/retro` has not run this session, offer to run it first.
- **Release any claim this session made.** If `/preflight` claimed an issue
  (assignee, `agent:*` label, card at `In Progress`), check what actually
  became of it — a claim left standing over abandoned or finished work is a lie
  the board tells the next reader, and it outlives the session that told it:

  ```sh
  gh issue view <n> --repo <owner/repo> \
    --json state,stateReason,assignees,labels,closedByPullRequestsReferences
  # PRs that actually reference this issue — cross-reference events, not text:
  gh api repos/<owner>/<repo>/issues/<n>/timeline --paginate \
    --jq '.[] | select(.event=="cross-referenced") | .source.issue
          | select(.pull_request) | {number, state: .state, url: .html_url}'
  ```

  Do **not** use `gh pr list --search <n>`: that is full-text search, so a low
  issue number matches version strings and commit summaries in unrelated PRs.
  Treating those as work in flight would suppress cleanup forever.

  **Before offering to clear anything, check nothing else is still working.**
  The markers are shared and converge (`track-work` §6), so a second session on
  the same GitHub identity is invisible in all of them. Another open PR
  referencing the issue, or activity newer than this session's claim comment,
  means the claim may not be yours alone to release — say so and let the user
  decide rather than presenting cleanup as obviously safe.

  Three outcomes:
  - **PR open** — the claim is accurate; `/shepherd` owns the card from here.
    Nothing to do.
  - **Merged / issue closed** — *not* "nothing to release". GitHub clears no
    marker on merge, and a personal-account project has no automation to move
    the card, so the work finishes and the board shows an agent still holding
    it. Offer the cleanup below — including its "undo only what the claim
    added" rule, which binds here too. Add `--status Done` **only with evidence
    the issue is actually finished**: it is closed as `completed`
    (`stateReason`), or a merged PR linked it with a *closing keyword*
    (`closedByPullRequestsReferences`). A merged PR that only says `Refs #N`
    finished part of it, and an issue closed `not planned` was never
    delivered — `Done` would be false in both. In those cases **restore the
    status the claim comment recorded** rather than leaving `Status` alone:
    `/shepherd` deliberately parks a `Refs`-only issue at `In Progress`, so
    doing nothing here leaves the board advertising an active claim over work
    that has stopped. (`/shepherd` never sets `Done` at all: it stops before
    the merge, so for it `Done` is a prediction rather than a record.)
  - **Neither** — the session stopped mid-flight. Offer the commands to hand
    the work back. `/preflight` set **four** markers, and clearing only some
    leaves the issue still advertising itself as held — the exact failure this
    step exists to prevent:

    **Undo only what the claim added.** The claim comment carries a "Claim
    record" listing which markers `/preflight` actually created. An issue can
    be assigned to you, or carry the label, *before* the claim — ordinary
    backlog ownership, which `/preflight` explicitly allows — and the writes
    are all add-if-missing, so on that path they changed nothing. Removing
    them anyway destroys state the session never created, and no amount of
    user approval recovers it, because by then nobody can tell which it was.
    Skip any line the record marks `no`; if no record survives, ask rather
    than assume the claim created everything.

    ```sh
    # Separate commands on purpose: the label is optional (/preflight skips it
    # where the family does not exist), and `--remove-label` on a label the
    # repo lacks fails the whole `gh issue edit` — taking the assignee removal
    # down with it and leaving the claim standing.
    gh issue edit <n> --repo <owner/repo> --remove-assignee @me          # only if the record says the claim added it
    gh issue edit <n> --repo <owner/repo> --remove-label agent:claude-code  # likewise
    # If the record names a displaced label, put it back — the claim removed it:
    gh issue edit <n> --repo <owner/repo> --add-label <displaced agent: label>
    <track-work-dir>/assets/set-issue-status.sh --repo <owner/repo> --issue <n> \
      --project "<the board the claim comment recorded>" \
      --status "<the status the claim comment recorded>"
    gh issue comment <n> --repo <owner/repo> --body-file -   # why it was handed back
    ```

    **Pass `--project`.** The record names the board the claim actually moved.
    An issue added to a second project since then makes the helper either
    prefer `<owner> Project` or refuse as ambiguous — restoring the wrong card
    while the claimed one stays at `In Progress`.

    **The hand-back comment must say it released the claim**, on its own line
    and verbatim, because the claim comment is never deleted and would
    otherwise keep reading as a live claim to every future `/orient`:

    ```text
    Claim released — <why>. (Supersedes the claim record above.)
    ```

    **Restore, don't reset.** The claim comment records the status the claim
    overwrote; put that back. Sending a shaped, prioritized issue to `Todo`
    silently discards planning state and can requeue it wrongly. If the comment
    says "unknown" or no comment survives, ask the user instead of picking —
    `Todo` and `Agent Queue` are guesses, not defaults.

    **Check the card first** (`set-issue-status.sh … --show`), because
    project-field edits leave no trace in the issue's history — a human's
    later decision is invisible unless you look. What you may restore depends
    on *who* last wrote the value:

    - `In Progress` — this claim wrote it. Restore. Where the record says the
      prior status was `none`, restoring means *clearing* the field, not
      picking a value — `set-issue-status.sh` only sets options, so that is
      manual (`gh project item-edit --clear`, or the board UI). Only
      `unknown` — a read that actually failed — needs the user.
    - `Verifying`, `In Review`, `Ready to Merge` — `/shepherd` wrote these for
      a PR. If that PR is now closed unmerged or abandoned, they are this
      lifecycle's own leftovers and no work is in flight: restore. Refusing
      here just strands the card mid-pipeline forever, which is the failure
      this whole step exists to prevent.
    - Anything else — `Icebox`, `Next`, `Shaping`, a status this lifecycle
      never writes — someone else moved it. Leave it and say what you found.

    **Leave the `Agent` field alone.** A claim never writes it — it records
    which agent *should* implement the issue, set at planning, while the
    `agent:*` label records which one *is*. Clearing it here would delete a
    planning decision the claim never made and the board's Agent-queue view
    depends on.

    Do not run any of it unasked — this is the user's call, and they may be
    resuming tomorrow.
- List anything left dangling as explicit handoff bullets for the next
  session.

## 3. Emit the rename

You cannot rename the session yourself — output the command for the user to
paste. Prefix the current name with `done-`; if it already starts with
`done-`, leave it as is:

```text
/rename done-dev-workflow-skills-138
```

## 4. Sign off

One-line summary of what the session accomplished. If the SessionEnd
transcript-archive hook is installed
(`templates/claude-hooks/session-end-archive/` in harmon-devkit), note that
the transcript will archive automatically when the session exits.
