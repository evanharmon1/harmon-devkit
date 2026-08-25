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
its release** — the orchestrator's — not the delegate executing the work; the
claim tooling pins the label to the claiming host's attested family, so a
delegate's family cannot be written there by construction. A
Claude session dispatching a Codex implementer still claims `claim:claude`;
the delegate is recorded in the claim record's informational `dispatched to`
line, which is where a reader looks for who was handed the work. That line
names the delegate the orchestrator is **about to dispatch** — the claim is
written immediately before the dispatch, so the value is the intended
delegate, and a dispatch that then fails or is aborted owes a refresh record
saying `none` (or an early hand-back). The record is never edited when the
delegate returns or is replaced: a redelegation posts a new claim record (the
ordinary refresh), and a reader wanting the current state looks at the latest
record plus the work in flight.

## Sequence

1. Claim the issue under the orchestrator's own identity and claim family —
   the user types `/claim` for it.
2. Dispatch the subagent with a self-contained brief.
3. Collect the subagent's report.
4. Carry on exactly as for the orchestrator's own work. The report ends the
   dispatch, not the claim: while review, CI, the PR, or another delegate is
   still in flight the claim stays live and follows the ordinary lifecycle:
   `/shepherd` retires the `claim:*` label at ready-for-review, and the close
   event or `/wrap` releases the claim itself.
   Hand the issue back early only when the report leaves nothing in flight:
   `partial` or `blocked` with no PR open.

Use this copy-pasteable brief addition for any delegated issue work:

```text
Do not claim the issue. The orchestrator owns its claim and release.

Report back with:
- issue(s) worked: <owner/repo#n>
- PR number(s) and URL, or "no PR"
- commit SHAs on the branch
- delivery status: delivered (every acceptance criterion met) | partial
  (list what remains) | blocked (why)
- follow-up issues filed: <owner/repo#n>; these carry no claim and that is
  expected
```
