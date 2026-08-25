# Orchestrated work

The rule: **the orchestrator claims; subagents never do.** Before dispatching
an issue, the orchestrating session follows
[`track-work` §6](../SKILL.md#6-making-an-agents-work-visible-while-it-happens)
to claim it itself. Several subagents can share one GitHub identity, and only
the orchestrator knows when the delegated work is complete.

## Sequence

1. Claim the issue under the orchestrator's own identity and claim family.
2. Dispatch the subagent with a self-contained brief.
3. Collect the subagent's report.
4. Release the claim, or leave it for `/wrap`, exactly as the orchestrator
   would for its own work.

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
