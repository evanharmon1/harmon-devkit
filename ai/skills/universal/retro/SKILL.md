---
name: retro
description: >-
  End-of-session retrospective — loose ends, follow-ups, next actions,
  improvement opportunities (skills to write, settings/env changes, GitHub
  issues to file), plus status tables with clickable links and status emoji
  for every PR and issue touched or referenced this session. Invoke as /retro.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh issue view:*)
---

# Retro

**Arguments:** $ARGUMENTS

End-of-session retrospective. Review the whole conversation, not just the
most recent work.

## 1. Gather PRs and issues

Enumerate every PR and issue that was worked on **or even referenced** during
the session. If the conversation has been compacted, the earlier context is
summarized and the enumeration is best-effort: say so explicitly, cross-check
`gh pr list --author @me` and the session's branches for work the summary may
have dropped, and note that the tables may be incomplete. Do not trust
remembered status — re-verify each one live:

- `gh pr view <n> --json state,isDraft,mergedAt,reviewDecision,statusCheckRollup,url,title`
- `gh issue view <n> --json state,stateReason,assignees,labels,url,title`

**Read the claim off the markers, not off the issue.** A live claim is an
`claim:*` (or legacy `agent:*`) label, a card at `In Progress`, or the
**latest trusted `Claiming —` comment after the latest trusted `Claim released —` comment**.
A newer trusted claim supersedes an earlier refresh record without releasing
the active claim; an older comment alone proves nothing about now.

Neither `state` nor `assignees` may gate that check. Both exclude real stale
claims: a closing PR auto-closes the issue while the label and card stay set,
and a `/wrap` that removed the assignee before failing on the label or status
leaves a claim with nobody assigned. Gating on either is how the claim this
step exists to surface becomes invisible. Do not require the label
specifically, either — `/claim` treats a missing `claim:*`/`agent:*` family as benign
and claims anyway, so demanding it would miss every claim in an older repo or
one with `project_management: none`, which are exactly the repos where the
label cannot exist. Report it as "open — claimed,
in progress", then check it is still true: a claim with no open PR and no work
in flight is a loose end for §2, not a status. `/wrap` offers the commands to
hand it back.

**Discovery trust is deliberately read-only and broader than cleanup trust.**
For this stale sweep, accept a claim author whose comment-time association is
`OWNER`, `MEMBER`, or `COLLABORATOR` even when that author is no longer a
current assignee; otherwise the partial-cleanup shape above disappears with
its assignment. This rule may surface a candidate but never authorizes a
write. `/wrap` and `release-claim.sh` must re-read current state and apply the
stricter cleanup trust gate before removing anything.

**A claim awaiting release is not a stale claim.** Two live claims read
identically off the markers and mean opposite things — distinguish them
rather than reporting both as loose ends:

- **Pending release** — *this session* claimed it, and its PR is open, in
  review, or awaiting merge. The release is owed to the close event
  (`claim-release.yml` where installed) or to `/wrap`, not overdue. Report
  it as part of the work's normal state, not as a loose end.
- **Stale** — the claim outlived its work: **nothing is in flight** (no open
  PR, no fresh activity), whichever session made it, or the issue is already
  **closed** with the label or assignee still standing. A session-name
  mismatch alone proves nothing — a claim from a different session with work
  in flight is *another session's active claim*: report it, never treat it
  as cleanup material. That last case means the release
  workflow failed or is not installed — say which, because "the automation
  missed one" and "there is no automation" call for different fixes
  (`track-work/references/claim-lifecycle.md`). One shape is *neither*: a
  closed issue whose card still sits at `In Progress` **under a trusted
  `Claim released —` comment** is a successful release awaiting board
  cleanup — the workflow has no Projects permission by design — so report
  it as a pending `/wrap` chore, not a workflow failure. These are §2
  loose ends.

Keep each reference's repository identity: a bare `#123` from another repo
must be verified with `--repo owner/repo` (or by its full URL), never against
the current repo's numbering.

## 2. Loose ends and next actions

- Uncommitted or unpushed work: `git status -sb`, and
  `git log @{u}..HEAD --oneline` (guard for branches with no upstream).
- Unresolved review threads on open PRs — `gh pr view` cannot report thread
  resolution, so use a read-only GraphQL query (this one is not pre-approved
  and will prompt):

  ```sh
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!,$c:String){
    repository(owner:$o,name:$r){pullRequest(number:$n){
      reviewThreads(first:100,after:$c){
        pageInfo{hasNextPage endCursor}
        nodes{isResolved path}}}}}' \
    -F o=<owner> -F r=<repo> -F n=<pr>
  ```

  If `hasNextPage` is true, repeat with `-F c=<endCursor>` until every page
  is seen — a thread past the first 100 can still block the PR.

- TODOs introduced during the session.
- Anything promised in conversation but not done.

List each as a concrete next action.

## 3. Improvement opportunities

- Skills worth writing or updating based on friction hit this session.
- Settings, hooks, or environment improvements.
- GitHub issues worth filing — draft a `(<free-form scope>): <imperative
  outcome>` title and one-line body for each, following `track-work`'s complete
  title contract, but do **not** create them unless asked.

## 4. Status tables

Emit exactly these two tables. Re-verified status only; short human status
text plus one emoji.

```markdown
## Pull requests

| PR | Status | |
| --- | --- | --- |
| [harmon-devkit#142 — feat: …](https://github.com/evanharmon1/harmon-devkit/pull/142) | merged | ✅ |
| [harmon-devkit#145 — fix: …](https://github.com/evanharmon1/harmon-devkit/pull/145) | open — checks failing | 🔴 |

## Issues

| Issue | Status | |
| --- | --- | --- |
| [harmon-devkit#138 — Create commands / skills…](https://github.com/evanharmon1/harmon-devkit/issues/138) | open — claimed, in progress | 🙋 |
```

Emoji legend (use these consistently):

- PRs: ✅ merged · 🟢 open, checks green · 🟡 open, review pending ·
  🔴 open, checks failing · ⚪ draft · 🗑️ closed unmerged
- Issues: 🟢 open · 🙋 open, assigned to me · ✅ closed completed ·
  ⚪ closed not planned

## 5. Wrap

Suggest `/wrap` as the final step of the session.
