# Cloud lanes

Use this mode only on the operator's explicit request. Never choose cloud lanes
unprompted or recommend them. The launch uses a new Herdr tab unless the operator
chooses a pane; the tab hosts the launch command, not an attached cloud agent. Change
nothing in the vendored Herdr skill.

## Preconditions and launch

The local Claude Code CLI must be signed in to claude.ai, have a default web
environment selected with `/remote-env` (`remote.defaultEnvironmentId`), and
have remote sessions permitted by `allow_remote_sessions`. The repository must
be on GitHub with the Claude GitHub App installed: then launch clones the remote
at the current branch. Otherwise the platform uploads the repository instead;
that is outside this mode. Claims are unchanged: the orchestrator claims before
launch, and the lane never claims or refreshes the claim.
Launch from a checkout on the default branch at its pushed tip, because the
platform clones the current branch; review fetched lane heads in a separate
worktree, never by switching the launching checkout.

Render `assets/cloud-lane-brief.md` into a file using the launch-time fields
below. The `brief` validator governs local PR-owning lane briefs; cloud briefs
use this render check instead: require every catalog field in the template,
substitute once, refuse any unreplaced `{{…}}`, require all four sections, and
refuse local report-file instructions or a literal Codex trigger.
Run this check on the rendered file before every launch; the template test pins
only that the template can pass it. Do not fabricate a branch, worktree, report
sentinel or branch-bound claim envelope: the platform chooses the `claude/*` branch.

| Field | Launch-time source |
| --- | --- |
| `{{lane-name}}` | Lane plan |
| `{{run-id}}` | Active run |
| `{{issue-url}}` | Canonical claimed issue URL |
| `{{deadline}}` | Run start plus resolved wall-clock ceiling |
| `{{policy-projection}}` | Resolved policy, including caps and role tiers |
| `{{file-scope-fence}}` | Lane ownership plan |
| `{{verified-facts-and-rulings}}` | Verified issue facts and attributed rulings |
| `{{gate-commands}}` | Repository gate commands |
| `{{gate-bounds-override}}` | Repository gate bounds, including tier |
| `{{cloud-report-path}}` | Fence-authorized pushed report path |
| `{{github-rest-read-path}}` | Environment's provided REST read command |

Launch from the target checkout in a new Herdr tab using the lane-launch section's
editor environment. In its terminal, or under a pseudo-terminal, run:

```sh
script -qec 'claude --cloud "$(cat brief.md)"' launch.log </dev/null
```

This is the verified Linux `script` form. The brief must come from a file:
`script -c` re-parses its argument, and inline backtick-quoted brief text ran
locally in the spike. Never interpolate the brief into that command string.
A Herdr terminal can instead run `claude --cloud "$(cat brief.md)"` directly.
Without a terminal it refuses with `Error: --cloud requires an interactive
terminal.` Capture `Created cloud session: <title>`, the `View:` session URL and
`Resume with: claude --teleport <session-id>` from the launch output.

## Message, watch and take back

Send steering from a file; this needs no terminal:

```sh
claude -p "$(cat msg.md)" --cloud <session-id> --output-format json
```

It queues the message and returns `{ok, session_id, url}`. Delivery is not
completion. There is no CLI way to read replies and no interactive attach:
`claude --cloud <session-id>` without `-p` fails with
`Error: Attaching to an existing cloud session is not enabled for your account.`
Use `-p` to message; Herdr cannot list, prompt or read this lane as an agent.
Do not use local agent-settle waits or pane sentinels for it.

Watch through GitHub. Snapshot `git ls-remote origin 'refs/heads/claude/*'`
before launch and compare after the lane pushes. Correlate the new branch with
the lane's issue, brief and pushed report; multiple unexplained candidates are
indeterminate, never a reason to guess. Once learned, pass the branch to:

```sh
bash <skill-dir>/assets/lane-watch.sh --state-file <run-dir>/lane-watch.state \
  --registry <kickoff-registry-snapshot> <deadline> \
  '<lane>:<claude/slug>:<nonce>:<owner/repo>:cloud'
```

The final `:cloud` selects GitHub-only observation: `BRANCH` reports pushed-head
changes or a deduplicated `BRANCH <lane>: absent` on a 404, `PR` reports the
matching PR and its head, and the usual post-promotion activity monitoring
remains in force.
An `absent` ref means deleted, renamed, never pushed or not visible to the token;
check the session before acting. No local worktree, report file or Herdr
agent read is used. A branch observation proves a push, not a passed gate: read
the lane's report and verify the exact head before proceeding. The lane reports
through its pushed branch, then the PR body section or comment when a PR exists;
never through `.lane-report.md`. The orchestrator's claim refresh through the
claim transaction records the learned branch, the draft's ordinary `pr` / `pr_bindings`
record the PR, and the session URL goes in the PR body.

`claude --teleport <session-id>` in a local terminal of the same repository
copies the session's branch and conversation into the local checkout. This take
back path is **untested**; do not describe it as a verified recovery procedure.

## Environment and review handoff

The web environment's GitHub proxy refuses GraphQL, so commands such as
`gh issue view` fail. Where the environment installs the agent posture (as
harmon-init's remote bootstrap does), raw `gh api` is denied too and
`/usr/local/bin/gh-api-read` supplies REST reads. Otherwise the brief names
whatever REST read path the environment provides. The orchestrator performs
claim, acceptance-criterion updates and integration with its own credentials.
A cloud VM never holds a Codex login; never ask the lane to log in to Codex.

`task verify` takes about 30 minutes there. Run long gates detached and poll the
log to the actual `GATE-EXIT=` line, retaining a failing or indeterminate result:

```sh
nohup bash -c 'task verify; echo GATE-EXIT=$?' > verify.log 2>&1 & disown
```

With network level Custom plus `semgrep.dev`, the cloud lane can run
`task security` itself. State the configured environment and the gates actually
run; do not infer success from a pushed branch or an expired wait.

The lane implements, runs the gates it can, commits and pushes its assigned
branch through the repository's push gates, reports, and stops without opening
a PR. The orchestrator fetches that exact pushed head into its review worktree
and runs the resolved `task challenge` and `task review` stages
from its logged-in pane, retaining their normal caps and adjudication records.
It sends confirmed fixes with `claude -p --cloud`, re-fetches the returned head,
and verifies the round gates. It then runs `task security`, opens the draft
with `gh pr create --draft --head <learned-branch>`, verifies draft/head state,
and integrates through the normal readiness gate. The PR body records
`reviewed from <host> at <head>`, naming the host and full reviewed SHA along
with stage results, policy disclosure and deferred findings. The orchestrator
owns review requests and all GitHub review text; the lane never writes an
at-sign immediately followed by the word `codex` into GitHub text.

## Recorded evidence

The 2026-10-11 spike (local CLI 2.1.293, web 2.1.296) verified start under a
pseudo-terminal in the `/remote-env` default and messaging without a human
relay. Two lanes were watched through pushed branches and carried to draft PRs:
[harmon-init#1620](https://github.com/evanharmon1/harmon-init/pull/1620) and
[harmon-init#1631](https://github.com/evanharmon1/harmon-init/pull/1631).
The [scope and spike record](https://github.com/evanharmon1/harmon-devkit/issues/1210)
records the attach error above. Teleport was not tested. The maintainer's
post-shipping end-to-end check remains a human follow-up; these spike results do
not mark that check complete.
