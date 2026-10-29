# Cloud lanes

Use this mode only on the operator's explicit request. Never choose cloud lanes
unprompted or recommend them. The launch uses a new Herdr tab unless the operator
chooses a pane; the tab hosts the launch command, not an attached cloud agent. Change
nothing in the vendored Herdr skill.

## Preconditions and launch

The local Claude Code CLI must be signed in to claude.ai, have a default web
environment selected with `/remote-env` (`remote.defaultEnvironmentId`), and
have remote sessions permitted by `allow_remote_sessions`. The session runs on
the account the CLI is signed in to (`claude auth status`), not the one open in a
browser, so that account must hold both the web environment and a GitHub
credential that reaches the repository, such as a `/web-setup` token. Then
launch clones the remote at the current branch. Without one, the platform uploads
the checkout with no `origin`, and the lane cannot push; that is outside this mode.
Claims are unchanged: the orchestrator claims before launch, and the lane never
claims or refreshes the claim.
Launch from a checkout on the default branch at its pushed tip, because the
platform clones the current branch; review fetched lane heads in a separate
worktree, never by switching the launching checkout.

Render `assets/cloud-lane-brief.md` into a file using the launch-time fields
below. The `brief` validator governs local PR-owning lane briefs; cloud briefs
use this render check instead: before inserting anything, require the template's
`{{…}}` placeholders to be exactly the catalog's fields; then insert every value
in one simultaneous pass and never rescan the inserted text. Require all four
sections, and refuse local report-file instructions or a literal Codex trigger.
Run this check for every launch; the template test pins only that the template
can pass it.
The orchestrator chooses `claude/<lane-slug>` before launch, records it in the
plan's lane assignment like any lane, refreshes the claim to that branch with
the claim transaction before launch, and passes the branch to the brief.
Pushes to a `claude/*` name other than the platform's session branch were
accepted in every session tried, but the platform does not promise it. A
blocked lane, including one whose push is refused, pushes nothing: its only
GitHub channel is a gated push, and the CLI cannot read session replies. No push
by the deadline is therefore indeterminate, and the operator reads the reason on
the session page, the one out-of-band channel. Before launch, require
that the remote has no `refs/heads/claude/<lane-slug>`
(`git ls-remote --exit-code origin refs/heads/claude/<lane-slug>` exits 2; only
exit status 2 means the ref is absent, and any other non-zero status, for example
128, is a failed read that blocks the launch or is retried, never counted as
absent); if it exists, choose a new slug, so the first head the watcher reports is this
launch's push.
`assets/fence-check.sh` needs a schema-bound brief, so it cannot check a cloud
lane; before the readiness gate, check instead that every changed path, both the
source and the destination of any rename or copy, is inside the planned lane
fence (`git diff -C --find-copies-harder --name-status <base>...<head>` lists them,
as fence-check.sh does).

| Field | Launch-time source |
| --- | --- |
| `{{lane-name}}` | Lane plan |
| `{{branch}}` | Orchestrator-chosen `claude/<lane-slug>` in the plan's lane assignment |
| `{{run-id}}` | Active run |
| `{{issue-url}}` | Canonical claimed issue URL |
| `{{deadline}}` | Run start plus resolved wall-clock ceiling |
| `{{policy-projection}}` | Resolved policy, including caps and role tiers |
| `{{file-scope-fence}}` | Lane ownership plan |
| `{{verified-facts-and-rulings}}` | Verified issue facts and attributed rulings |
| `{{gate-commands}}` | Repository gate commands |
| `{{gate-bounds-override}}` | Repository gate bounds, including tier |
| `{{github-rest-read-path}}` | Environment's provided REST read command |

Launch from the target checkout in a new Herdr tab using the lane-launch section's
editor environment. In its terminal, or under a pseudo-terminal, run:

```sh
BRIEF='<run-dir>/<lane>/brief.md' MODEL='<model>' EFFORT='<effort>' \
  script -qec 'claude --cloud "$(cat "$BRIEF")" --model "$MODEL" --effort "$EFFORT"' \
  '<run-dir>/<lane>/launch.log' </dev/null
```

This is the verified Linux `script` form. The brief must come from a file:
`script -c` re-parses its argument, and inline backtick-quoted brief text ran
locally in the spike. Never interpolate the brief into that command string.
A Herdr terminal can instead run
`claude --cloud "$(cat "$BRIEF")" --model "$MODEL" --effort "$EFFORT"` directly.
`<model>` and `<effort>` are the implementer profile the orchestrator resolved;
they are the dispatch-attested values it records at PR open with
`record-implementer.sh apply`. The cloud session honours them: on 2026-10-12 the
session page of the end-to-end check's first launch showed the pinned model and
effort.
Without a terminal it refuses with `Error: --cloud requires an interactive
terminal.` Capture `Created cloud session: <title>`, the `View:` session URL and
`Resume with: claude --teleport <session-id>` from the launch output. Keep the
rendered brief and `launch.log` in the run directory: until the draft PR exists,
`launch.log` is the record of the session ID, and a resumed driver reads it there.

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

Watch the known branch from the plan through GitHub:

The cloud lane's `:cloud` spec joins the slate's single watcher under SKILL.md's
one-watcher rule; it is never run as a second watcher.

```sh
bash <skill-dir>/assets/lane-watch.sh --state-file <git-common-dir>/dev-flow-v2/slates/<slate-id>/lane-watch.state \
  --registry <kickoff-registry-snapshot> <deadline> \
  '<lane>:claude/<lane-slug>:<nonce>:<owner/repo>:cloud' 2>&1
```

For a `:cloud` lane, the nonce is any per-lane token (for example the lane name),
because the watcher validates its shape but does not read it.

The final `:cloud` selects GitHub-only observation: `BRANCH` reports pushed-head
changes or a deduplicated `BRANCH <lane>: absent` on a 404, `PR` reports the
matching PR and its head. Cloud lanes inherit the same continuous PR watch:
`PR-ACTIVITY`, `PR-THREAD`, `PR-CI` and `PR-BEHIND`, with `PR-MERGED` and
`PR-CLOSED` terminal events. On lane retirement replace the cloud spec with
`'<label>:<pr-number>:<nonce>:<owner/repo>:pr'` in the same watcher and retain
its state file. This PR-only watch covers promoted and parked drafts past the
run deadline until merge or close; it never reads a branch or local lane. Periodic `HEARTBEAT` summaries include cloud lanes with
branch/PR last-change age and PR state. There are no cloud `PROMPT` or `STALL`
events because there is no local pane.
An `absent` ref means deleted, renamed, never pushed or not visible to the token;
check the session before acting. No local worktree, report file or Herdr
agent read is used. A branch observation proves a push, not a passed gate: read
the lane's report and verify the exact head before proceeding. The lane reports
in the body of its final commit message on each push, so no report file enters
the diff; read it with `git log -1 --format=%B <head>` after fetching, never
through `.lane-report.md`. The orchestrator's claim refresh through the
claim transaction records the chosen branch, the draft's ordinary `pr` / `pr_bindings`
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
g="$(mktemp /tmp/gate.XXXXXX)"
cat >"$g" <<'GATE'
task verify
echo GATE-EXIT=$?
GATE
nohup bash "$g" >"$g.log" 2>&1 & disown
printf 'GATE-LOG=%s.log\n' "$g"
```

With network level Custom plus `semgrep.dev`, the cloud lane can run
`task security` itself. State the configured environment and the gates actually
run; do not infer success from a pushed branch or an expired wait.

The lane implements, runs the gates it can, commits and pushes the orchestrator-chosen
branch through the repository's push gates, reports, and stops without opening
a PR. The orchestrator fetches that exact pushed head into its review worktree
and runs the confidence stages through `/review` against that head (its finders
run `task challenge` and `task review` from the logged-in pane), so the run keeps
its normal caps and adjudication records.
Confirmed fixes follow `/review`'s ordinary remediation: a reserved agent run, a
fresh bounded implementer in a local worktree of the planned branch, and a push
through `round-push.sh`. The cloud session is never re-messaged to apply a fix;
its work ends at its first report. The orchestrator then runs `task security`, opens the draft
with `gh pr create --draft --head <planned-branch>`, verifies draft/head state,
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
records the attach error above. Teleport was not tested.

The post-shipping end-to-end check ran from 2026-10-12 to 2026-10-14 and ended
in [harmon-devkit#1465](https://github.com/evanharmon1/harmon-devkit/pull/1465).
Its fourth launch worked end to end: the orchestrator launched it with no human
step under a pseudo-terminal into the `/remote-env` default, saw its pushed
branch through GitHub, and carried the work to a draft PR.
The lane pushed exactly its planned `claude/*` branch, as the account's
`/web-setup` identity, and reported in its commit body. That lane was not
messaged. Messaging with `claude -p … --cloud <id>` was exercised on the first
launch, where a steering note and two rulings reached the session and changed
what it did. The lane's `Claude-Session` commit trailer named a different
session ID from the one its launch printed; which one identifies the session
was not established. Of the three earlier launches, the first and third had no
GitHub credential that reached the repository, so the platform uploaded the
checkout with no `origin`: at the first, the account's GitHub connection did not
cover the repository, and the third ran after that account's GitHub connector
had been disconnected following `/web-setup`. The second was abandoned before it
reported, when the CLI was found signed in to a different account from the one
holding the credential.
