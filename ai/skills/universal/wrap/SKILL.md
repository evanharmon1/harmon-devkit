---
name: wrap
description: >-
  End-of-session ritual — check for uncommitted or unpushed work, release
  any issue claim left standing, list anything dangling, and emit the
  copy-pasteable /rename done-<session-name> command for the user. Invoke as
  /wrap.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(gh issue view:*), Bash(gh pr list:*)
---

# Wrap Session

Formerly `/close`.

**Arguments:** $ARGUMENTS

Wrap up the session and rename it `done-<name>` so finished sessions are easy
to distinguish in the session picker and the Claude mobile app.

## 1. Recover the session name

Look for `/kickoff`'s "Session name: `<name>`" line in the conversation. If it
is not in context, **ask the user** for the current session name (they can
read it in the UI) — never guess.

## 2. Wrap up

- `git status -sb` for uncommitted work; `git log @{u}..HEAD --oneline` for
  unpushed commits (guard for branches with no upstream).
- If `/retro` has not run this session, offer to run it first.
- **Release any claim this session made.** If `/claim` claimed an issue
  (assignee, `claim:*` label, card at `In Progress`), check what actually
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
  decide rather than presenting cleanup as obviously safe. One exemption: the
  closing PR's own trail. A merged PR that delivered this claim's work
  necessarily leaves cross-reference, merge, and closure events newer than the
  claim comment — that is the claim's expected end of life, not somebody
  else's work, and counting it would make the merged path below ask every
  time. What counts is *unrelated* newer activity: another open PR, a claim
  comment you did not write, someone else's hands on the markers.

  **Every path that clears a marker must say it released the claim.**
  Whichever outcome applies below, any cleanup that removes or restores a
  marker ends with a comment carrying, on its own line and verbatim:

  ```text
  Claim released — <why>. (Supersedes the claim record above.)
  ```

  The claim comment is never deleted, so without this supersede line the
  issue keeps reading as a live claim to every future `/kickoff` and `/retro`
  — clearing the markers without it recreates exactly the state this step
  exists to prevent. Post it **last, and only when every applicable marker
  write succeeded**: a supersede comment over a marker that survived — a
  board restore that failed on a missing `project` scope, say — tells every
  future sweep the claim is settled while stale state remains, which is worse
  than no comment. For the board write, "succeeded" means the card actually
  reached the intended status (`set-issue-status.sh` exit 0): a card that
  exists but whose board lacks the target option comes back exit 3 without
  moving, and that is an *incomplete* cleanup for this rule — only "the
  issue is on no board at all" is genuinely nothing-to-do. If any write fails, report the partial cleanup to the user
  instead of posting the release line. The converse failure — markers cleared
  but the release comment refusing to post — must not end silent either:
  retry the post, and if it still fails restore **a searchable marker that
  actually existed and fabricates no ownership** — re-add the assignee you
  just removed (always writable, even where the record marks the label
  `n/a`); a displaced label you already restored counts too, and never
  re-add your own `claim:*` label beside it, which would leave the issue
  claiming two owners. The point is that the half-released claim stays
  findable by `/kickoff`'s sweep instead of surviving only as a card and an
  unsuperseded comment. If that restore also fails, nothing was writable —
  say exactly that; the user is present on this path.

  New records may also carry optional `harness`, `model`, and `session` lines.
  Read them as operational context when present, and accept older records that
  omit them. They are never cleanup authority: do not use their values to
  select, construct, or suppress any write in any outcome below.

  Three outcomes:
  - **PR open** — the claim is accurate; `/shepherd` owns the card from here.
    Nothing to do.
  - **Merged / issue closed** — *not* "nothing to release". GitHub clears no
    marker on merge, and a personal-account project has no automation to move
    the card, so the work finishes and the board shows an agent still holding
    it. (Where the `claim-release.yml` workflow is installed, the close event
    already released the label, assignee, and claim comment — the probes
    above will show a `Claim released —` supersede; what remains for this
    step is the board, which the workflow never touches. See
    `track-work/references/claim-lifecycle.md`.) This outcome does not stop
    at describing the problem: **assemble the
    full cleanup — the block below, under its "undo only what the claim
    added" rule, finishing with the `Claim released —` supersede comment
    above — and run it on a single confirmation**, presented as the default
    next action, not a question about whether cleanup is wanted. One
    keystroke is the whole cost, and it is what bounds the residual races a
    multi-command release can never close on its own (`track-work` §6:
    markers are non-atomic and same-identity sessions converge). Streamline
    to that single confirmation only when **both** hold:

    - the claim record survives, is **authored by the account you are
      authenticated as** (`gh api user --jq .login` — the same authority
      check `/implement` §1 applies, because on a public repo anyone can post
      a claim-shaped comment and a forged record must not steer marker
      writes), and accounts for every marker the cleanup would touch, and
    - the issue is **currently closed `completed`** (`stateReason`), with the
      closure postdating this claim's comment (read `closedAt` alongside
      `stateReason`). `completed` is deliberately the *only* accepted reason:
      it is what a closing-keyword merge sets, so a merged delivery always
      qualifies — while `not planned` and duplicate closes never do, whatever
      historical closers `closedByPullRequestsReferences` retains from before
      a reopen. Do not treat that list as delivery evidence on its own: it
      keeps unmerged and pre-reopen PRs forever.

    **Re-read the ground immediately before the first write** — the probes
    above may be minutes old, and the analysis between them and the cleanup
    is exactly where a reopen or a fresh claim lands unseen. Re-run *both*
    §2 probes (`state,stateReason,assignees,labels` plus the timeline
    cross-references) **and** re-fetch the comments and the card (`--show`):
    a second session on the same GitHub identity is visible only in a new
    claim comment or a new PR, never in the converging markers. Any change
    from what the conditions were judged on returns this to stop-and-ask,
    the same pre-write re-read `/claim` performs before claiming.

    Otherwise **stop and ask** — in particular when no claim record survives,
    the record says `prior board status owned by this claim chain: unknown`
    (or, for a legacy record, `prior board status: unknown`), another agent's `claim:*`
    (or legacy `agent:*`) label is present, another open PR still references the issue, or the card
    sits at a status this lifecycle never writes.

    (The single confirmation is about *judgment*, not tool permissions: the
    agent does not debate whether cleanup is wanted, and every write below
    still runs under the harness's normal permission prompting — this
    skill's `allowed-tools` deliberately pre-approves only reads, and
    widening it would silently auto-approve mutations everywhere the skill
    is vendored.)

    **Skip the displaced-label restore line on this path.** The record's
    displaced label exists so a mid-flight hand-back can return the issue to
    the agent it was taken from; putting another agent's label back onto
    finished, closed work would advertise a live claim over nothing — the
    exact state this cleanup removes.

    Add `--status Done` **only with evidence
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
    the work back. `/claim` set **four** markers, and clearing only some
    leaves the issue still advertising itself as held — the exact failure this
    step exists to prevent:

    **Undo only what the current claim chain owns.** The current claim comment
    carries a "Claim record" listing which markers `/claim` actually created
    and, in v2, which predecessor ownership it inherited. An issue can
    be assigned to you, or carry the label, *before* the claim — ordinary
    backlog ownership, which `/claim` explicitly allows — and the writes
    are all add-if-missing, so on that path they changed nothing. Removing
    them anyway destroys state the session never created, and no amount of
    user approval recovers it, because by then nobody can tell which it was.
    Use the three core `claim chain` fields when present; their optional
    assignee-login companion identifies an inherited assignment's owner, and
    the chain board-status field preserves the status the chain originally
    overwrote. They are authoritative current ownership and hand-back
    provenance after a refresh or takeover. Restore the chain board status
    rather than the direct prior status on a current chain record. Skip any
    line the record marks `no`; if no record survives, ask rather than assume
    the claim created everything.

    ```sh
    # Separate commands on purpose: the label is optional (/claim skips it
    # where the family does not exist), and `--remove-label` on a label the
    # repo lacks fails the whole `gh issue edit` — taking the assignee removal
    # down with it and leaving the claim standing. A marker already released
    # by /shepherd's green stop or the claim-release workflow makes its
    # command a harmless no-op — skip its line rather than re-releasing.
    #
    # Board FIRST, searchable markers LAST. The board write is the one that
    # fails for environmental reasons (missing `project` scope), and the
    # assignee and `claim:*` label are what /kickoff's stale-claim sweep
    # queries — clear them before a failed board write and the leftover card
    # becomes undiscoverable (the board-only gap, harmon-devkit#183).
    # The recorded board title and status are external data — a project title
    # can contain `$(…)` or backticks, and pasting it inside double quotes
    # executes it before the helper runs. Paste both inside single quotes
    # exactly as recorded. A title that itself contains a single quote cannot
    # be single-quoted: load it without any shell evaluation via a quoted
    # heredoc, then pass the variable —
    #   IFS= read -r TITLE <<'RECORDED_TITLE_EOF'
    #   <paste the title verbatim>
    #   RECORDED_TITLE_EOF
    # and use --project "$TITLE". Status options are custom text too — the
    # same form (a second heredoc into STATUS) covers a recorded status
    # containing a quote.
    <track-work-dir>/assets/set-issue-status.sh --repo <owner/repo> --issue <n> \
      --project '<the board the claim comment recorded>' \
      --status '<the chain board status, or direct prior status for a legacy record>'
    # If the record names a displaced label, put it back — the claim removed it:
    gh issue edit <n> --repo <owner/repo> --add-label <the displaced label the record names>
    gh issue edit <n> --repo <owner/repo> --remove-label <the exact label the record says the claim added>  # e.g. claim:claude, model-pinned claim:claude:opus, or legacy agent:claude-code
    gh issue edit <n> --repo <owner/repo> --remove-assignee @me          # likewise
    gh issue comment <n> --repo <owner/repo> --body-file -   # why it was handed back
    ```

    **Pass `--project`.** The record names the board the claim actually moved.
    An issue added to a second project since then makes the helper either
    prefer `<owner> Project` or refuse as ambiguous — restoring the wrong card
    while the claimed one stays at `In Progress`.

    **The hand-back comment is the release comment** — it must carry the
    `Claim released —` supersede line above, verbatim, like every other path
    that clears a marker.

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

    **Leave the `Agent` field alone.** It is retired, and a claim never wrote
    it — advisory routing now lives in the `suggest:*` label and live ownership
    in the `claim:*` label. If a legacy `Agent` value still lingers on an old
    board, it is a planning artifact this claim never set, so clearing it here
    would delete a decision the claim never made. Release only what the claim
    record says the claim added.

    Do not run any of this mid-flight hand-back unasked — the work is being
    handed back, not finished, so it is the user's call: they may be resuming
    tomorrow. (That caution is scoped to this branch on purpose. The merged
    path above needs only its single go-ahead — nothing is being resumed
    there, and its two conditions already route every ambiguous case to a
    full stop-and-ask.)
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
