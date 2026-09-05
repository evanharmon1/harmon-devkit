---
name: retro
description: >-
  End-of-session retrospective — start from the run's retained Dev flow v2
  evidence where one exists (per-stage rounds against their caps, findings by
  class and provenance, overrides, interventions), fall back to the
  memory-based sweep where none does, then loose ends, follow-ups, next
  actions, improvement opportunities (skills to write, settings/env changes,
  GitHub issues to file), plus status tables with clickable links and status
  emoji for every PR and issue touched or referenced this session.
  Invoke as /retro.
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh issue view:*)
---

# Retro

**Arguments:** $ARGUMENTS

End-of-session retrospective. Review the whole conversation, not just the
most recent work.

## 1. Start from the run's retained evidence

Dev flow v2 leaves a durable record per run — a run record and one adjudicated
round comment per confidence round on the issue, a stage projection on the PR
(`specs/dev-flow-v2.md` § Evidence; the byte-level grammar is in
`ai/schemas/README.md` "Evidence marker and digest grammar"). Where one exists
for this session's PR, **every measurement in §2 comes from it, not from
recollection.** What a session remembers about its own rounds is exactly the
thing a retrospective must not take on trust: the rounds it spent, what the
findings were about, where the orchestrator overrode a reviewer, and where a
human had to step in are all recorded, and a remembered version of any of them
is a reconstruction after the fact.

**Two different markers, two different jobs.**

- The **PR body's rendered sections** — `<!-- dev-flow:begin:policy-disclosure -->`,
  `deferred-findings`, `adjudication-record`, published by
  `scripts/render-dev-flow.mjs` — say a v2 record exists and carry the
  **resolved rigor line**, which is where §2's caps come from. They do not
  carry the run id.
- The **run id** lives in the evidence markers themselves,
  `<!-- devflow:<kind> v2 run_id=<id> … -->`: on the PR's stage-rollup
  comments, and — authoritatively, because the record is anchored on the
  issue — in the `run-index` / `run-record` comments on the linked issue. A
  marker counts only as the **first line** of a comment; one quoted inside
  prose (a real risk on a PR that discusses this protocol) is not a run.

**Run the projection rather than reading the trajectory by hand.** It resolves
the run id, calls the harvester (`scripts/dev-flow-stats.mjs --run <id> --json`,
issue #663) and renders §2's fixed sections:

```sh
<retro-skill-dir>/assets/retro-run-report.mjs --repo <owner/repo> --pr <n>
```

Resolve `<retro-skill-dir>` from `.agents/skills/retro`, then
`.claude/skills/retro`, then `ai/skills/universal/retro` in harmon-devkit
itself. The helper is read-only — it shells out to `gh` reads and to the
harvester (`scripts/dev-flow-stats.mjs`, which never writes) — but it is
deliberately **not** in `allowed-tools`, so expect a permission prompt, the
same as the GraphQL query in §4.

Useful arguments: `--run <run_id>` when you already know it (a run that capped
before its PR existed has no PR to discover from — its record is on the issue);
`--trusted-actor-id <id>` when the run was orchestrated by an account other
than the one you are authenticated as, typically Foreman's service account;
`--as-of <iso8601>` to reconstruct the run as it stood at an earlier instant;
`--json` for the machine form.

**Branch on the exit code. Do not read the text and guess.**

| Exit | Meaning | What the retro does |
| --- | --- | --- |
| 0 | a report is on stdout | Paste it as §2, then carry on |
| 10 | no retained evidence — `no-stats-script`, `no-run-record`, or `run-not-found` | Fall back: skip §2, and **say plainly** that this session has no run record so the improvements in §5 rest on the conversation rather than on measurements |
| 11 | evidence exists but is **indeterminate** — a broken or forged digest chain, or two runs claimed on one PR | Not a fallback. Make it the retro's first finding, quote the reason from stderr, and file it |
| 1 or 2 | operational or usage error | Fix the invocation, or report that the tool failed. Never silently downgrade to memory |

Exit 10 is the ordinary pre-v2 session and costs the retro only its evidence
section. Exit 11 is a finding in its own right — treating it as "no evidence"
is how tampered evidence would read as an ordinary memory-based retro.

## 2. The run-evidence report

Paste the helper's output verbatim. Its sections are fixed, in this order, so
two retros of two different runs are comparable line for line:

1. `## Run evidence` — run id, issue, PR, who initiated it, outcome, promotion,
   and where the run id was discovered.
2. `### Policy the run was reviewed under` — the resolved rigor line read back
   off the PR body. This is the budget the run **actually** ran under, not
   whatever `.devflow.toml` says today; a retro that rescored an old run
   against a since-edited config would invent disagreements that never
   happened. Where the PR published no disclosure the caps are reported
   unknown rather than guessed.
3. `### Stage <name>`, one per stage the run entered, chronologically by first
   entry — rounds spent against the cap, findings and passes, rounds with no
   adjudication record, every entry and exit (a stage re-entered by a
   remediation loop keeps **one** section holding all of its rounds), and the
   interventions that landed while that stage was open.
4. `### Findings by class and provenance` — `class` from the reviewer's own
   finding, `provenance` its `original` / `round:N` field.
5. `### Overrides` — the cap, waiver, tier, and strategy disclosures the PR
   published.
6. `### Interventions` — every human touchpoint, with the stage it interrupted.
7. `### Deferred findings settled` — each settled deferral with the finder slug
   recovered from its finding id (`<stage>-r<round>-<finder>-<n>`, the slugs
   `agent-registry.json` `finders[]` declares).
8. `### Evidence integrity` — trusted-but-unlisted and forged-author comments.
9. `### Not measurable from this run's evidence` — the measurements this retro
   is expected to make that today's evidence surface cannot supply, each naming
   the issue that would close it. Carry these into §5 as-is rather than
   silently omitting them; an absent section reads as "nothing to report".

**How to read it.** The numbers are the input to §5, and four of them carry
most of the signal:

- **Rounds against the cap.** A stage that spent its cap converged late or not
  at all. A stage that exited on round 1 spent nothing it did not need to.
- **The `round:N` share of provenance.** A stage whose later findings are
  mostly about its own earlier fixes is feeding on itself — the exact failure
  AGENTS.md's round-2 scaffolding checkpoint exists to catch. If the trajectory
  shows it, the improvement cites that stage, its convergence policy or skill,
  and this run id.
- **Interventions.** Each one is a place the run could not proceed unattended,
  and the closed-cohort success metric counts them. Ask what would have had to
  be true for each not to happen.
- **Integrity.** A forged-author or orphan comment is a finding about the
  evidence protocol, not a footnote.

Where §1 fell back, skip this section entirely and say so — do not
reconstruct these headings from memory. A section that looks measured but was
recalled is worse than an absent one.

## 3. Gather PRs and issues

Enumerate every PR and issue that was worked on **or even referenced** during
the session. If the conversation has been compacted, the earlier context is
summarized and the enumeration is best-effort: say so explicitly, cross-check
`gh pr list --author @me` and the session's branches for work the summary may
have dropped, and note that the tables may be incomplete. Do not trust
remembered status — re-verify each one live:

- `gh pr view <n> --json state,isDraft,mergedAt,reviewDecision,statusCheckRollup,url,title`
- `gh issue view <n> --json state,stateReason,assignees,labels,url,title,comments`
  — one response, so the marker check below reads labels and the claim
  comments (including any `dispatched to` line) from a single snapshot; a
  second call could pair pre-release markers with a post-release comment

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
in progress" — and when the latest claim record carries a `dispatched to`
line whose value is not `none`, say so ("claimed, dispatched to …" with the
recorded delegate). That line is dispatch-time history, not live state: it
says the orchestrator handed the issue to a background subagent when the
record was written, and it is the only place the tracker records that. Whether
the delegate is still active is read from the work in flight, exactly as for
any other claim. Then check it is still true: a claim with no open PR and no
work in flight is a loose end for §4, not a status. `/wrap` offers the commands to
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
  it as a pending `/wrap` chore, not a workflow failure. These are §4
  loose ends.
- **Freshly filed follow-up** — an issue an agent filed during this session as
  follow-up work is expected to be open, unassigned, and without a claim.
  Report it under "filed," not as a loose end. It becomes a loose end only if
  this session said it would work the follow-up and did not.

Keep each reference's repository identity: a bare `#123` from another repo
must be verified with `--repo owner/repo` (or by its full URL), never against
the current repo's numbering.

## 4. Loose ends and next actions

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

- Deferred findings the PR body still leaves unchecked — the checkbox is the
  resolution state, so an unticked `- [ ]` under `## Deferred findings` is open
  work whatever the conversation remembers.
- TODOs introduced during the session.
- Anything promised in conversation but not done.

List each as a concrete next action.

## 5. Improvement opportunities

**Every item names the thing it would change.** One of:

- a **stage** — `challenge`, `review`, `integration`, …
- a **skill** — `/implement`, `/integrate`, `/retro`, …
- a **config key** — `.devflow.toml`'s `[rounds].challenge`, `default_rigor`,
  a `[convergence]` predicate, …
- a **registry or schema contract** — `agent-registry.json`'s `finders[]`, a
  `result.*.schema.json` field, …

An item that names none of those is an observation, not an improvement: find
its target or drop it. Where §2 ran, each item cites the measurement it came
from ("challenge spent 3 of 3 rounds with 2 of 4 findings at `round:1`
provenance") rather than an impression.

Within that shape, look for:

- Skills worth writing or updating based on friction hit this session.
- Settings, hooks, or environment improvements.
- Every entry from §2's `### Not measurable from this run's evidence` — each
  already names its target and its follow-up issue.
- GitHub issues worth filing — draft a `(<free-form scope>): <imperative
  outcome>` title and one-line body for each, following `track-work`'s complete
  title contract, but do **not** create them unless asked.

**A follow-up filed from a retro carries the run's provenance.** When asked to
file, go through the `track-work` skill and give the issue a `## Provenance`
line naming the run, so a later reader can replay the trajectory the finding
came from rather than take the retro's word for it:

```markdown
## Provenance

Retro of Dev flow v2 run `<run_id>` (issue #<n>, PR #<n>), `<stage>` stage.
```

Where §1 fell back, provenance names the session and the date instead, and
says there was no run record — an honest "no measurement behind this" is worth
more than a run id that does not exist.

## 6. Status tables

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

## 7. Wrap

Suggest `/wrap` as the final step of the session.
