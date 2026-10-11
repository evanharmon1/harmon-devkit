# Cloud lanes

Use this mode only on the operator's explicit request. Never choose or recommend
cloud lanes unprompted. Launch in a new Herdr tab by default, with a pane as an
option; the tab hosts the launch command, not an attached cloud agent. Change
nothing in the vendored Herdr skill.

## Preconditions and launch

The local Claude Code CLI must be signed in to claude.ai, have a default web
environment selected with `/remote-env` (`remote.defaultEnvironmentId`), and
have remote sessions permitted by `allow_remote_sessions`. The repository must
be on GitHub with the Claude GitHub App installed: then launch clones the remote
at the current branch. Otherwise the platform uploads the repository instead;
that is outside this mode. Claims are unchanged: the orchestrator claims before
launch, and the lane never claims or refreshes the claim.

Render the cloud variant in `assets/lane-brief.md` into a file. Keep the resolved
policy, run identity, ownership fence and issue facts, but replace local
worktree/report and PR-owning procedures with that variant. The platform chooses
the lane's `claude/*` branch; do not promise a pre-provisioned local branch or
apply the ordinary brief's branch-bound claim refresh to it. Record the existing
claim handoff and then the learned branch without transferring claim ownership.

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
changes, `PR` reports the matching PR and its head, and the usual post-promotion
activity monitoring remains in force. No local worktree, report file or Herdr
agent read is used. A branch observation proves a push, not a passed gate: read
the lane's report and verify the exact head before proceeding. The lane reports
through its pushed branch, then the PR body section or comment when a PR exists;
never through `.lane-report.md`. Record each lane's session URL, learned branch,
and PR URL/number (pending until created) in the run's registered evidence
comment, updating the run record's PR binding when the orchestrator opens it.
Keep these together on resume; do not add undeclared fields to `run.json`.

`claude --teleport <session-id>` in a local terminal of the same repository
copies the session's branch and conversation into the local checkout. This take
back path is **untested**; do not describe it as a verified recovery procedure.

## Environment and review handoff

The web environment's GitHub proxy refuses GraphQL, so commands such as
`gh issue view` fail. Under the agent posture, raw `gh api` is denied too: the
lane uses `/usr/local/bin/gh-api-read` for REST reads. The orchestrator performs
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
a PR unless told to. The orchestrator fetches that exact pushed head into its
own checkout and runs the resolved `task challenge` and `task review` stages
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
