---
name: close
description: >-
  Close-of-session ritual — check for uncommitted or unpushed work, list
  anything left dangling, and emit the copy-pasteable
  /rename done-<session-name> command for the user. Invoke as /close.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git:*), Bash(gh:*)
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
