# Orchestrated work

The rule: **the orchestrator claims; subagents never do.** Before dispatching
an issue, the orchestrating session claims it under
[`track-work` §6](../SKILL.md#6-making-an-agents-work-visible-while-it-happens)
— and `/claim` is user-invocable only, so the route is the user typing
`/claim` for that issue: ask for it before dispatching. Neither a decision to
delegate nor a conversational go-ahead authorizes the claim writes by itself.
Several subagents can share one GitHub identity, and only the orchestrator
knows when the delegated work is complete.

The `claim:<family>` label names the family **accountable for the claim and
its release** — the orchestrator's — not the delegate executing the work;
the claim tooling pins the label to the claiming host's attested family, so
a delegate's family cannot be written there by construction. A
Claude session dispatching a Codex implementer still claims `claim:claude`;
the delegate is recorded in the claim record's informational `dispatched to`
line, which is where a reader looks for who was handed the work. That line
names the delegate the orchestrator is **about to dispatch** — the claim is
written immediately before the dispatch, so the value is the intended
delegate, and a dispatch that then fails or is aborted owes a refresh record
saying `none` (or an early hand-back). With several delegates on one issue
at once, the line is the **complete set**, comma-separated on the one line,
and every refresh rewrites the whole set as it stands — adding a delegate
never drops one still active. The record is never edited when a delegate
returns or is replaced: a redelegation posts a new claim record (the
ordinary refresh), and a reader wanting the current state looks at the latest
record plus the work in flight.

## Sequence

1. Claim **every** issue the brief covers under the orchestrator's own
   identity and claim family — the user types `/claim` for each — before
   any dispatch. A brief that spans issues leaves none of them unclaimed.
2. Prepare the checkout **before** dispatching: a feature branch off the
   default branch with a clean tree. The shipped implementer refuses to edit
   on the default branch and never creates a branch itself, so a dispatch
   from the default branch produces nothing. A single delegate may share the
   orchestrator's checkout only while the orchestrator makes no edits of its
   own; **each concurrent delegate gets its own worktree**
   (`task worktree:new -- <name> --base origin/<default>` where the repo
   provides it — without `--base` the new branch forks from the main
   worktree's HEAD, which may be another feature branch) — the
   implementer requires a clean tree and commits as it goes, so two workers
   in one checkout collide through the shared index or stop on each other's
   uncommitted edits. If the branch the claim record names changes, post a
   refresh record.
3. Dispatch the subagent with a self-contained brief.
4. Collect the subagent's report.
5. Carry on exactly as for the orchestrator's own work. The report ends the
   dispatch, not the claim: while review, CI, the PR, or another delegate is
   still in flight the claim stays live and follows the ordinary lifecycle:
   `/shepherd` retires the `claim:*` label at ready-for-review, and the close
   event or `/wrap` releases the claim itself. With several delegates on one
   issue, do not take any of its PRs through `/shepherd`'s ready-for-review
   stop until every delegate for that issue has reported — that stop retires
   the label, and "implementing right now" is still true while another
   delegate runs.
   Hand the issue back early only when the report leaves nothing in flight:
   no PR open **and** no commits kept on the branch — a `partial` or
   `blocked` report whose commits stay on a feature branch is unfinished
   work, and the claim stays live until that branch is abandoned (deleted or
   explicitly parked in the hand-back) or carried to a PR.

Use this copy-pasteable brief addition for any delegated issue work:

```text
Do not claim the issue. The orchestrator owns its claim and release.

Report back with:
- issue(s) worked: <owner/repo#n>
- PR number(s) and URL, or "no PR"
- commit SHAs on the branch
- delivery status: delivered (every acceptance criterion met) | partial
  (list what remains) | blocked (why)
- follow-up work discovered: none | a draft per follow-up (title, body,
  target repository), or <owner/repo#n> only where this brief authorized
  filing it
```

The follow-up line accepts a draft because a delegate cannot ask for the
go-ahead an issue write needs mid-task: the orchestrator files the draft (or
delegates filing with the full delegated-creation contract from `track-work`
§5) after the report. A follow-up filed either way carries no claim, and that
is expected.
