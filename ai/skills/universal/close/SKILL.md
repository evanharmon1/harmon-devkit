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

Look for `/start`'s "Session name: `<name>`" line in the conversation. If it
is not in context, **ask the user** for the current session name (they can
read it in the UI) — never guess.

## 2. Wrap up

- `git status -sb` for uncommitted work; `git log @{u}..HEAD --oneline` for
  unpushed commits (guard for branches with no upstream).
- If `/reflect` has not run this session, offer to run it first.
- **Release any claim this session made.** If `/preflight` claimed an issue
  (assignee, `agent:*` label, card at `In Progress`), check what actually
  became of it: `gh issue view <n> --repo <owner/repo> --json state,assignees`
  plus whether a PR is open for it. A claim left standing over abandoned or
  finished work is a lie the board tells the next reader, and it outlives the
  session that told it. Three outcomes:
  - **PR open** — the claim is accurate; `/shepherd` owns the card from here.
    Nothing to do.
  - **Merged / issue closed** — nothing to release, but say so.
  - **Neither** — the session stopped mid-flight. Surface it and offer the
    commands to hand the work back. `/preflight` set **four** markers, and a
    hand-back that clears only some leaves the issue still advertising itself
    as held — which is the exact failure this step exists to prevent. All
    four:

    ```sh
    gh issue edit <n> --repo <owner/repo> --remove-assignee @me \
      --remove-label agent:claude-code
    <track-work-dir>/assets/set-issue-status.sh --repo <owner/repo> --issue <n> \
      --status Todo   # or "Agent Queue" if it should stay queued for an agent
    gh issue comment <n> --repo <owner/repo> --body-file -   # why it was handed back
    ```

    The `Agent` field is the fourth. `set-issue-status.sh` only *sets*
    single-select options, so clearing it is manual — `gh project item-edit
    --clear` on the item, or the board UI. Say so rather than leaving it set;
    an `Agent` value with no `In Progress` status still reads as "an agent has
    this".

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
