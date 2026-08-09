# Codex second-model review

A second AI model — the [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
— reviews changes in this repo: manual review/challenge tasks, plus an optional
automatic Claude Code → Codex stop-gate. Those tasks are local and advisory:
nothing runs in CI, no PR check depends on Codex, and `verify`/`ci` never invoke
it. Repositories can separately opt into a required current-head result from
Codex cloud review during PR shepherding. Findings are hypotheses for the
primary agent to adjudicate — the protocol and the loop caps live in AGENTS.md
("Second-Model Review").

## Setup

1. **Install the Codex CLI**: `brew install --cask codex` (macOS) or
   `npm install -g @openai/codex` (anywhere Node ≥ 18 runs).
2. **Authenticate**: `codex login` (browser OAuth against a ChatGPT account —
   the free tier has tight usage limits) or
   `printenv OPENAI_API_KEY | codex login --with-api-key` (billed API usage).
   Confirm with `codex login status`.
3. **Trust the repo in Codex** when prompted on first run. The committed
   `.codex/config.toml` raises the project-instruction budget to 64 KiB; project
   config only loads for trusted repositories. The review scripts explicitly
   pin review work to `gpt-5.6-sol` with high reasoning.
4. **For the automatic stop-gate only — the Claude Code codex plugin.** This
   repo's `.claude/settings.json` declares the `openai-codex` marketplace and
   enables `codex@openai-codex`, so Claude Code installs/offers the plugin
   when you trust the folder. Manual install, inside Claude Code:

   ```text
   /plugin marketplace add openai/codex-plugin-cc
   /plugin install codex@openai-codex
   /codex:setup
   ```

5. **If `use_codex_cloud_review` is enabled, connect this repository to Codex
   cloud review for PR shepherding.** The Copier opt-in adds the policy but
   cannot grant GitHub access: a maintainer must connect Codex through ChatGPT
   and allow the repository in the GitHub connector. Availability and quotas
   depend on the maintainer's ChatGPT plan, and private repositories require
   explicit connector access. Cloud review is a required shepherd signal, not
   a required GitHub status check; if it stays unavailable for both bounded
   attempts, the agent stops and escalates.

6. **Then disable Codex Automatic reviews** — personal Auto review off, and the
   repository's Auto code review preference set to **Follow personal**. Codex
   triggers a cloud review on three events: opening a PR for review, marking a
   draft ready, and an explicit `@codex review`. Only the third is usable here:
   the PR is a draft for the whole automated lifecycle, so the first never
   fires, and the second fires *after* the readiness gate — starting a new
   asynchronous review at the exact moment "non-draft" is supposed to mean the
   automated work is done. No API reports this setting, so it is a
   human-configured prerequisite recorded in docs/CHECKLIST.md; the readiness
   gate trusts that record and must never claim it was mechanically verified.

## Manual reviews

| Command | What it does |
|---|---|
| `task challenge` (= `challenge:codex`) | Adversarial review — tries to break the change: architecture, authz bypasses, data-loss paths, unsafe rollback, races, hidden coupling, operational failure modes, needless complexity |
| `task review` (= `review:codex`) | Verification checkpoint — double-checks implementation, consistency with repo conventions, error handling, and test coverage |

Both accept an explicit target and free-text focus after `--`:

```bash
task challenge                                     # auto: commits beyond the base AND uncommitted work — whatever exists
task challenge -- --base main                      # committed history only, vs main explicitly
task review -- --uncommitted                       # staged + unstaged + untracked only
task challenge -- --base main focus on the update/migration path
```

With no target flag, **both halves of the change are in scope**: the commits
beyond the auto-detected base (`origin/HEAD`, else a local `main`/`master`)
*and* the working tree. When both exist the prompt carries one manifest split
into a `Committed changes` and an `Uncommitted changes` section, so the
reviewer knows which diff to collect for each path; when only one exists it is
reviewed on its own. If the base cannot be resolved at all, the run refuses
(exit 2) rather than falling back to the worktree half — a partial review that
exits 0 is indistinguishable from a clean pass. The explicit flags stay narrow
deliberately — `--base` is committed history only and `--uncommitted` is the
worktree only — so they remain escapes you opt into rather than a default that
quietly drops half the change.

Whichever target you pick, an empty one is refused before Codex is invoked,
with a non-zero exit. An empty scope has no correct outcome — the model either
invents one or declines, and a decline reads exactly like a clean pass, so a
capped challenge/review round would be spent banking a review that never
happened. `--base` on a dirty tree also says so on stderr: it reviews
committed history only, and the uncommitted work it excludes is often the very
change you meant to review.

`--base` also warns when the ref you named lags its own upstream and your
branch already carries some of the difference — `--base main` on a checkout
whose local `main` trails `origin/main` puts those already-merged commits
inside `main...HEAD`, so the review spends a round on findings against files
your branch never touched. The warning counts the already-merged commits caught
in the scope and names the remote-qualified alternative (`--base origin/main`),
and it is advisory: an intentionally older base still runs. Partly-updated
branches count too — rebasing onto a mid-point of the gap still leaves those
commits in scope. It stays quiet when the base has no upstream (a tag, a sha,
`origin/main` itself), when your branch carries none of the upstream commits,
when the base has run *ahead* of its upstream rather than behind, and when the
gap changes no files at all (a change and its revert) — the two scopes are
byte-identical there, so there is nothing to warn about.

Inside Claude Code the plugin's slash commands are the interactive
equivalents: `/codex:review` and
`/codex:adversarial-review --base main --background` (with extra focus text
allowed after the flags), plus `/codex:status` / `/codex:result` for
background runs.

### Duration and backgrounding

A round is **minutes, not seconds** — 5–15 is ordinary and passing ten is not
unusual. The cost tracks how much the reviewer *reads*, not how large the diff
is: it re-reads AGENTS.md, this guide, and whatever those point at on every
round, so a three-line docs change can run as long as a feature branch.

That is longer than a typical agent's tool-call timeout (Claude Code's Bash
tool caps at 600s), so an agent must **start these tasks in the background and
poll** rather than blocking one call on them — otherwise an ordinary round
surfaces as a timeout and reads like a hang. Use the harness's own background
execution (in Claude Code, the Bash tool's background option): it owns the
process, reports completion, and can cancel the run and its children. Where a
harness has no such primitive, run the task in a terminal you can watch —
do not hand-roll a supervisor around it in the shell, which trades a ten-minute
wait for orphaned processes, races over shared log files, and a completion
signal that the reviewed diff can spoof.

Two things not to change when backgrounding:

- **The target.** Bare `task challenge` keeps the auto-selection above — the
  branch's commits and the working tree, whichever exist. At this point in the
  loop the tree is normally dirty *and* the branch has commits, so a hardcoded
  `-- --base main` would review the committed branch and silently skip the
  very work being challenged (and name the wrong base in a repo that does not
  use `main`). Add a target flag only when you mean to narrow. Note
  `origin/HEAD` is a *cached* ref: if the remote's default branch moved,
  refresh it with `git remote set-head origin --auto`, or the auto-selected
  base is silently the old one.

  The explicit scopes do not overlap: `--uncommitted` reads the worktree,
  `--base` diffs commits, and **neither covers both**. That is why passing one
  mid-loop is risky — an uncommitted fix under `--uncommitted` narrows the
  re-run to just that fix, and the clean pass then attests to the fix rather
  than to the whole change. Bare `task challenge` covers both halves, so it is
  the right thing to re-run. Committing each round's fixes first is still
  tidier (it keeps the committed half authoritative and shrinks what Codex has
  to reconcile), but the loop's exit condition no longer depends on your
  remembering to.
- **The runner.** Background `task challenge` itself, not
  `/codex:adversarial-review --background`: the slash command calls Codex
  directly, so it never receives the P0/P1/P2 scale that
  `scripts/codex-review.sh` writes into the prompt. Fine for an interactive
  spot-check; it cannot establish the clean pass this loop gates on.

**Then leave the tree alone until it finishes.** `codex-review.sh` captures the
file manifest at launch, but Codex collects the diffs itself as it runs — so
editing, staging, or committing mid-review has it read a repository that no
longer matches the manifest, and committing an initially dirty tree empties an
explicit `--uncommitted` scope outright. Backgrounding buys polling, not
parallel edits: if there is other work to do, do it after the verdict. Should
you capture the output to a file, keep it under `git rev-parse --git-path`
rather than in the worktree — for the same reason the deferred-findings
sidecar lives there, a stray worktree file lands in the next bare
`task challenge`'s scope as part of the change under review.

**Still running is not hung.** `codex exec` streams events as it works, so
growing output is the liveness signal — poll it instead of inferring. Long
gaps between events are normal, and relaunching never resumes a run, it starts
a fresh one, so re-running a live review doubles both the wall clock and the
Codex usage the first one already spent. Bound the patience rather than the
run: if the output has been static for **~20 minutes** — well past any normal
gap — treat it as wedged on a stalled API call rather than thinking, cancel it
through the harness that started it, and only then start over.

## The automatic stop-gate

```bash
task codex:gate:enable    # turn on for this repo on this machine
task codex:gate:disable   # turn off
task codex:gate:status    # inspect
```

Disarming the gate is a human-only action, enforced in layers: the toggles
sit in `permissions.ask` in `.claude/settings.json`, and `disable`
additionally refuses to run without an interactive terminal — permission
prefix rules alone can be sidestepped with flag placement (e.g.
`task --silent codex:gate:disable`), but agent shells never have a TTY. A
gated agent must never disable the gate to get past a BLOCK — adjudicate or
escalate instead. (This is friction against silent disarmament, not an
absolute boundary: the plugin's own `/codex:setup --disable-review-gate` is
outside this repo's control, which is why the AGENTS.md prohibition exists.)
`enable` also refuses when the plugin is explicitly disabled in Claude Code
settings (`enabledPlugins`): an installed-but-disabled plugin registers no
Stop hook, so the armed flag would report protection that does not exist.

Mechanics: the codex plugin registers a Claude Code **Stop hook**. While the
gate is enabled for a workspace, every time Claude finishes a turn the hook
runs a fresh, read-only Codex task over the repo and Claude's last message;
Codex answers `ALLOW:` or `BLOCK: <reason>`. A block feeds the reason back
into Claude, which must address it (or refute it — see the adjudication
protocol) before it can finish. Non-editing turns are allowed through.

The tasks flip the same per-workspace `stopReviewGate` flag as
`/codex:setup --enable-review-gate` (plugin data dir keyed by workspace path
— note a git worktree is a different workspace with its own flag; the state
is per-user and per-machine, never committed). Fail-open is **narrower than
it looks**: only a missing codex binary makes the hook log guidance and let
Claude stop. An installed-but-unauthenticated codex makes the review task
fail, which the hook converts into a **block on every turn** — so
`task codex:gate:enable` refuses to arm the gate unless `codex login status`
succeeds, and if auth expires while the gate is on, recover with
`codex login` or `task codex:gate:disable` (disable/status never require
auth; disable does require an interactive terminal).

Loop safety: Claude Code caps consecutive stop-hook continuations, and repo
policy caps the adversarial/review loops (AGENTS.md "Dev Loop"). The
gate reviews after **every** turn while enabled and each run costs Codex
usage — enable it for high-consequence work (migrations, auth, concurrency,
release plumbing), disable it for routine development.

## Intended workflow

```text
task check      # fast inner loop while editing
task verify     # definition-of-done gate
task challenge  # adversarial second model — adjudicate, fix, re-challenge
                # until a CLEAN pass (no P0/P1 findings), ≤4 rounds
task review     # verification checkpoint — same clean-pass exit, ≤4 rounds
task ci         # full CI mirror
# → open a DRAFT PR, then shepherd it: watch CI + reviews, settle the deferred
#   P2s, adjudicate → fix → push, ≤4 rounds (independent of the loops above)
# → readiness gate passes → gh pr ready (the handoff to a human)
# → merging stays a human decision
```

The full staged loop — including the PR-shepherding rounds and the readiness
gate that ends them — is defined in AGENTS.md ("Dev Loop"). The PR is a
**draft** for every stage above: it is the agent's workbench, and promoting it
is the one signal that the automated work is finished.

If Codex cloud review is connected to the repo, PRs
get a cloud pass too: inline comments only for high-priority findings, a
👍 from the pinned Codex bot actor ID `199175422` on the exact
`@codex review` trigger comment as the clean pass. That reaction must post
after both the current head was pushed and its review request was created.
Those requests are explicit and made while the PR is draft — which is why
Automatic reviews must be off (setup step 6): an automatic review triggered by
`gh pr ready` would land after the gate that promoted the PR.

## Finding priorities

Both modes ask Codex to label every finding, and the local loops gate on that
label:

| Priority | Meaning | Gates `challenge`/`review`? |
| --- | --- | --- |
| `P0` | Breaks correctness, security, or data integrity in ordinary use, or breaks an existing contract | Yes |
| `P1` | A real defect or materially wrong design decision with a plausible trigger | Yes |
| `P2` | Worth knowing, not merge-blocking: hardening, unlikely edge cases, maintainability, non-critical test gaps | No |

The scale lives in the prompt that `scripts/codex-review.sh` builds — not in
the Codex CLI's own priority labels, which are an undocumented convention
that can change. Keeping the definition local means the gate still means what
it says when Codex's output format moves.

P2s are **reported, adjudicated, and deferred**, never suppressed: they carry
to the PR-shepherd stage, where they are fixed, declined with reasoning, or
filed as follow-up issues. That keeps the expensive local loops focused on
what actually blocks a merge, without losing the smaller findings.

The deferral needs somewhere to land. These tasks run **locally** — their
output lives in a terminal and nowhere else — and the cloud reviewer reposts
only high-priority findings, so a deferred P2 that is not written down is
gone. Write each one into the **PR description** under a
`## Deferred findings` heading, as an unchecked task-list item:

```markdown
## Deferred findings

- [ ] scripts/foo.sh:42 — P2: retry loop has no upper bound
```

Both tasks run before `gh pr create`, so write each finding down the moment
you defer it, in the git directory rather than the worktree:

```bash
note="$(git rev-parse --git-path \
  "deferred-findings/$(git branch --show-current)")"
mkdir -p "$(dirname "$note")"
cat >>"$note" <<'DEFERRED'
- [ ] scripts/foo.sh:42 — P2: retry loop has no upper bound
DEFERRED
```

One file **per branch**: an ordinary clone switches branches in place, so a
single shared sidecar would let branch B's PR absorb branch A's findings — and
then delete A's only copy when it clears the file. The branch name is used as
a path rather than flattened, so `feat/x` and `feat-x` stay distinct — and
without an extension, so `foo` cannot block `foo.md/bar`. That makes the
sidecar tree mirror git's ref namespace, which already forbids one live
branch from being a path prefix of another.

The **quoted** heredoc delimiter is load-bearing: findings routinely quote
code with backticks or `$(…)`, and inside a double-quoted string the shell
would run it. Quoting disables expansion, not termination — so pick a
delimiter the finding text cannot contain.

Check the file before appending: a stage only exits on a *clean re-run*, so an
unchanged P2 comes back every remaining round and again in the next stage. Add
it once, matching on location and substance rather than exact wording.

Move the list into the PR description when you open the PR, then delete the
file — and sweep the tree for strays while you are there:

```bash
ls -R "$(git rev-parse --git-path deferred-findings)"
```

Renaming or deleting a branch strands its notes under the old name, where
nothing looks for them again. Account for every file the sweep shows: adopt an
orphan if it belongs to this work, otherwise leave it and mention it. One
command beats rename-migration logic that would need its own correctness
argument. The location is deterministic, so a later session finds it the same
way, and `git status` never sees it — a note left in the *worktree* would be
worse than none, because a dirty tree puts it in the next bare
`task challenge`'s scope: a file of open findings, handed to the reviewer as
part of the change to adjudicate.

The shepherd stage settles every entry and ticks it off in the body as it
goes, so the checkbox — not anyone's memory — is what says whether a finding
is still open. The PR is not ready for review while an unchecked entry remains.
AGENTS.md ("Dev Loop") carries that obligation, so it holds even where the
optional `/shepherd` skill that automates it is not installed.

Note that the automatic stop-gate is not on this scale — the plugin's Stop
hook uses its own notion of a material finding and may BLOCK on a P2.
Adjudicate it; never disable the gate to get past a BLOCK.

## Troubleshooting

- **`codex` not found** — install per Setup; on Linux/devcontainers use the
  npm install (the Homebrew `codex` cask is macOS-only).
- **Auth expired** — `codex login status`, then `codex login` (or
  `codex login --device-auth` without a browser).
- **`/codex:*` commands missing in Claude Code** — trust the folder so the
  repo-declared plugin installs, or install manually (Setup step 4), then
  restart Claude Code.
- **Gate toggle "plugin not installed"** — the `codex:gate:*` tasks drive the
  plugin's own runtime under `~/.claude/plugins`; install the plugin first
  (Setup step 4).
- **Gate enabled but nothing happens** — `task codex:gate:status`; remember
  the flag is per workspace path (worktrees toggle separately) and fails open
  when Codex is unavailable.
- **Nothing to review** — the resolved target is empty, so the run refuses
  (exit 1) instead of asking Codex to review nothing; the message names the
  condition and the way out. Reaching it from `task challenge` with no flags
  means a clean tree with no commits beyond the base. Reaching it from
  `--base <ref>` usually means the work is still uncommitted — drop the flag
  to review both halves, or use `--uncommitted`.
- **Could not resolve a base to review this branch against** — no
  `origin/HEAD` and no local `main`/`master`, or the detected base shares no
  history with `HEAD` (exit 2). It refuses on a dirty tree too, rather than
  quietly reviewing the worktree alone: which commits are missing is exactly
  what cannot be determined, and a partial review that exits 0 reads as a
  clean pass. Fix the cached ref (`git remote set-head origin --auto`), name a
  base with `--base <ref>`, or say the worktree really is the whole target
  with `--uncommitted`.
- **A captured log is enormous, and the verdict is buried** — the CLI logs
  some errors with the entire API response inlined, so one line can run to
  hundreds of kilobytes and a retry loop repeats it. `codex-review.sh` bounds
  each **stderr** line to `CODEX_REVIEW_MAX_STDERR_BYTES` (default 1024) and
  marks what it cut; stdout, where the verdict is, is never filtered. Set the
  variable to `0` to capture a payload in full when debugging the CLI itself.
  A recurring dump usually means the CLI is older than the API it is talking
  to — compare `codex --version` against the version your devcontainer image
  ships, and rebuild or pull a newer image if it lags.
