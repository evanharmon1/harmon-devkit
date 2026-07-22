# Codex second-model review

A second AI model — the [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
— reviews changes in this repo: manual review/challenge tasks, plus an optional
automatic Claude Code → Codex stop-gate. Everything is local and advisory:
nothing runs in CI, no PR check depends on Codex, and `verify`/`ci` never
invoke it. Findings are hypotheses for the primary agent to adjudicate — the
protocol and the loop caps live in AGENTS.md ("Second-Model
Review").

## Setup

1. **Install the Codex CLI**: `brew install --cask codex` (macOS) or
   `npm install -g @openai/codex` (anywhere Node ≥ 18 runs).
2. **Authenticate**: `codex login` (browser OAuth against a ChatGPT account —
   the free tier has tight usage limits) or
   `printenv OPENAI_API_KEY | codex login --with-api-key` (billed API usage).
   Confirm with `codex login status`.
3. **Trust the repo in Codex** when prompted on first run. The committed
   `.codex/config.toml` (review-grade `model_reasoning_effort = "high"`; model
   deliberately unpinned) only loads for trusted projects.
4. **For the automatic stop-gate only — the Claude Code codex plugin.** This
   repo's `.claude/settings.json` declares the `openai-codex` marketplace and
   enables `codex@openai-codex`, so Claude Code installs/offers the plugin
   when you trust the folder. Manual install, inside Claude Code:

   ```text
   /plugin marketplace add openai/codex-plugin-cc
   /plugin install codex@openai-codex
   /codex:setup
   ```

## Manual reviews

| Command | What it does |
|---|---|
| `task challenge` (= `challenge:codex`) | Adversarial review — tries to break the change: architecture, authz bypasses, data-loss paths, unsafe rollback, races, hidden coupling, operational failure modes, needless complexity |
| `task review` (= `review:codex`) | Verification checkpoint — double-checks implementation, consistency with repo conventions, error handling, and test coverage |

Both accept an explicit target and free-text focus after `--`:

```bash
task challenge                                     # auto: dirty tree → uncommitted; clean → --base main
task challenge -- --base main                      # branch vs main explicitly
task review -- --uncommitted                       # staged + unstaged + untracked only
task challenge -- --base main focus on the update/migration path
```

Inside Claude Code the plugin's slash commands are the interactive
equivalents: `/codex:review` and
`/codex:adversarial-review --base main --background` (with extra focus text
allowed after the flags), plus `/codex:status` / `/codex:result` for
background runs.

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
                # until a CLEAN pass (no material findings), ≤5 rounds
task review     # verification checkpoint — same clean-pass exit, ≤4 rounds
task ci         # full CI mirror
# → open the PR, then shepherd it: watch CI + reviews, adjudicate → fix →
#   push, ≤4 rounds (independent of the loops above)
# → merging stays a human decision
```

The full staged loop — including the PR-shepherding rounds — is defined in
AGENTS.md ("Dev Loop"). If Codex cloud review is connected to the repo, PRs
get a cloud pass too: inline comments only for high-priority findings, a
bare 👍 reaction as the clean pass.

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
- **Nothing to review** — a clean tree with no commits beyond the base exits
  early; pass `--base <ref>`, `--uncommitted`, or `--commit <sha>` to pick
  the target explicitly.
