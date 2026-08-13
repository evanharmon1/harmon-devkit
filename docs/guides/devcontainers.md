# Devcontainers

Harmon DevKit ships a **dual-profile** devcontainer. Both profiles share
one `Dockerfile` and the baked `.devcontainer/config/` tree; they differ in
which secrets and capabilities they allow.

| Profile | Path | For | GitHub auth | Tailscale |
|---|---|---|---|---|
| **Bot** | `.devcontainer/devcontainer.json` | AI agents (Claude Code, Codex, Gemini) | the bot's PAT via `GH_TOKEN` | no |
| **Dev** | `.devcontainer/dev/devcontainer.json` | humans | the operator's own `gh auth login` | yes (`TS_AUTHKEY`, `--device=/dev/net/tun`) |

Each profile authenticates as the identity it commits as, and the omissions are
what make that true: the bot profile leaves `TS_AUTHKEY` off its allow-list so a
tailnet key never reaches an agent container, and the dev profile leaves
`GH_TOKEN` off so a bot credential never reaches a human one.

**Claude permission mode differs by profile.** The **bot** defaults to
`bypassPermissions` (Claude runs tools without per-action prompts — the container
is the isolation boundary); the **dev** profile keeps the normal prompt-on-action
default so a human stays in the loop. The shared managed settings
(`config/claude-settings.json`) deliberately omit `defaultMode`; the bot opts in
at create time via `scripts/enable-claude-bypass.sh`. `bypassPermissions` is only
safe because it is container-scoped — it is never set on the host.

**Codex follows the same split.** Both profiles default to `gpt-5.6-sol` with
medium reasoning and a 64 KiB project-instruction budget. The **dev** profile
uses `workspace-write`, `on-request`, and Auto-review: the sandbox defines the
writable boundary, while eligible exits from it are reviewed automatically.
The **bot** changes the managed config to `danger-full-access` plus `never`, so
there is no nested sandbox or interactive prompt inside Docker. Repository
instructions, hooks, GitHub token scope, mounted volumes, and Docker itself
remain the bot's boundaries.

**Codex follows the same split.** Both profiles default to `gpt-5.6-sol` with
medium reasoning and a 64 KiB project-instruction budget. The **dev** profile
uses `workspace-write`, `on-request`, and Auto-review: the sandbox defines the
writable boundary, while eligible exits from it are reviewed automatically.
The **bot** changes the managed config to `danger-full-access` plus `never`, so
there is no nested sandbox or interactive prompt inside Docker. Repository
instructions, hooks, GitHub token scope, mounted volumes, and Docker itself
remain the bot's boundaries.

**Antigravity autonomy is enabled for the bot profile.** It applies
`always-proceed`, always accepts artifact reviews, allows non-workspace access,
disables Antigravity's inner terminal sandbox, and trusts the current container
workspace. The human profile keeps Antigravity's normal prompts. Run `agy`
interactively once to complete Google sign-in; the pinned CLI falls back to
file-backed credentials when the headless container has no D-Bus keyring, and
the `~/.gemini` named volume persists that login. A checksum-verified
compatibility installer covers the interval before the shared-image pin
advances, then becomes a network-free no-op. The settings helper backs up the
four policy keys it owns and tracks its workspace-trust entry, so turning the
Copier option off restores both while preserving unrelated settings.

## Run it locally

- **VS Code:** "Dev Containers: Reopen in Container" → pick the **Dev** profile
  (`.devcontainer/dev/`) for human use.
- **CLI:** `devcontainer up --workspace-folder . --config .devcontainer/dev/devcontainer.json`

Prebuilt images are pulled from GHCR as a build cache
(`ghcr.io/evanharmon1/harmon-devkit-devcontainer` / `ghcr.io/evanharmon1/harmon-devkit-devcontainer-dev`), so a warm rebuild
is fast. A cache miss is non-fatal — it just rebuilds from the `Dockerfile`.

## Claude Code settings in the container

Everything is sourced from `.devcontainer/config/` and baked into the **image**,
so a volume wipe can never leave the container without its policy, hooks, or
status line:

| What | Lives at | Source | Overridable |
|---|---|---|---|
| Managed settings | `/etc/claude-code/managed-settings.json` (image) | `config/claude-settings.json` | no (policy) |
| Hook scripts (mandatory) | `/etc/claude-code/hooks/` (image) | `config/claude-hooks/` | no |
| Hook scripts (optional) | `/usr/local/share/devcontainer-config/claude-hooks/` (**staged**) | `config/claude-hooks/` | no |
| Status line | `/etc/claude-code/statusline.sh` (image) | `config/claude-statusline.sh` | yes |
| User defaults | `~/.claude/settings.json` (**volume**) | `config/claude-user-defaults.json` | yes |

Two rows for hooks, because they are not installed the same way. A **mandatory**
hook is listed in the image installer's `required_files`, so every image is
guaranteed to place it under `/etc/claude-code/hooks/`. An **optional** hook —
currently `session-end-archive.sh` — is installed only when the repository
ships it, so a settings entry naming the `/etc` copy would break the moment the
image pin were rolled back past the release that added it. Those are registered
at their **staged** path instead, where the repository's own
`COPY .devcontainer/config/` puts them regardless of which image is pinned.

The practical consequence when troubleshooting: for an optional hook, the copy
under `/etc/claude-code/hooks/` is **not** the one that runs. Inspect or replace
the staged copy, and check `managed-settings.json` for the path actually
registered rather than assuming it.

The last row is the one exception, and deliberately so: `~/.claude/settings.json`
is volume-backed because Claude Code writes your in-app changes there. Every
`post-create` **seed-merges** the image copy into it — existing values win, so
`/model` and friends stick, and a wiped volume gets the defaults back. What the
volume never holds is the code those settings point at.

`config/claude-statusline.sh` renders a four-line status line matching the one a
host session shows:

```text
📁 ~/git/harmon-devkit  🌿 main  PR #512 ✓  ▪ session name  · a1b2c3d4
🧠 ▕████░░░░░░░░░░░░▏ 24%  760k left  🤖 Opus 5 1M · medium · ⚡ · 💭  📟 v2.1.220
💰 $0.43  ✎ +120/-45  ⏱ 11m session
🚦 5h ▕█░░░░░░▏ ⧖ 2h13m   ·   7d ▕░░░░░░░▏ ⧖ 4d20h
```

Reading down: where you are, how much room and horsepower are left, what the
session has cost, and how close the 5-hour and 7-day subscription limits are to
biting (`⧖` is time until that window resets). Segments that would say nothing
are omitted rather than shown empty — the PR only appears on a branch that has
one, `⚡` and `💭` only when fast mode and extended thinking are on, and the
launch directory only when it differs from the one you are in. Unknown is not
empty: a payload carrying no context percentage renders `🧠 context n/a`, never
a 0% bar over a window that may be nearly full.

Both gauges fill as they are consumed and shift mint → peach → coral past 60%
and 80%; the limit bars run the same scale at under half the width in a muted
palette, so they read as the same thing at lower priority. `NO_COLOR` is
honored, and `STATUSLINE_CTX_WIDTH`, `STATUSLINE_RL_WIDTH`, `STATUSLINE_RL_PCT`
(exact limit percentages) and `STATUSLINE_HYPERLINK` (the OSC-8 link behind the
PR number) tune the rest.

It is built to be cheap, because it re-renders constantly: two forks per render
(`jq` and `date`), no `git` subprocess — the branch is read from `.git/HEAD`
directly, worktrees included — and nothing written to disk.

To use your own instead, point `statusLine.command` in `~/.claude/settings.json`
at it — the seed merge will not overwrite it.

### Fable 5 is unselectable in `/model`

**Symptom.** Fable works on your host but the container's `/model` picker
refuses it, complaining about usage credits — on an account that is entitled
to Fable. `claude --model fable --print 'hi'` in the same container succeeds,
which is the tell: the API is fine and the block is client-side.

**Cause.** Fable needs a one-time "draws from usage credits" consent, stored
**per machine** in `~/.claude.json` under `.fableOverageConsentV2`, keyed by
the signed-in account's `organizationUuid` (or `acct:<accountUuid>`).
`~/.claude` is a container-local volume, so the consent you granted on the
host never reaches the container.

Without the record, Claude Code arms a credits gate on the first API response
reporting overage-in-use — the setter is guarded by "no consent recorded", so a
machine that already has it never arms the gate at all. Accepting the resulting
prompt then live-checks extra usage, and if the account's cached
`cachedExtraUsageDisabledReason` is `out_of_credits` that path dead-ends. So
the in-app dialog cannot get you out of it, which is why this needs a manual
write.

**Fix.** Once per container, **with no `claude` session running**:

```sh
CJ=~/.claude/.claude.json
KEY=$(jq -r '.oauthAccount
  | if .organizationUuid then .organizationUuid
    elif .accountUuid then "acct:" + .accountUuid
    else empty end' "$CJ")
if [ -z "$KEY" ]; then
  echo "not signed in yet — run claude once, then re-run this"
else
  (umask 077
   jq --arg k "$KEY" \
     '.fableOverageConsentV2 = ((.fableOverageConsentV2 // {}) | .[$k] = true)' \
     "$CJ" >"$CJ.tmp") && mv "$CJ.tmp" "$CJ"
fi
```

Then start Claude Code. It merges rather than replaces, so re-running it is
harmless and another account's consent is left alone; the temp file is a
sibling of the target so the replacement is an atomic rename.

Two details in there are load-bearing rather than style. The `if` guards the
write: with a bare `[ -n "$KEY" ] || echo …`, execution continues on failure
and the update records consent under an **empty key**, corrupting the file it
was meant to fix. And `umask 077` keeps the new file at `0600` — a plain
redirect creates it with your umask, and the `mv` would then hand
`~/.claude.json`, which holds OAuth account state, looser permissions than it
started with.

Two things make the timing matter. Claude Code caches `.claude.json` in memory
at startup and never re-reads it, so a write during a session cannot affect
that session — and the CLI's next config write serializes its stale copy back
over the file, discarding the record. Run it between sessions.

The `~/.claude` volume survives rebuilds, so this is once per *new* container,
not once per rebuild. It is deliberately **not** automated: the key is a
billing authorization, and a hook baked into a shared image would grant it for
whichever account happened to sign in — including in repos templated from here.
Running the command yourself is the consent.
## Codex CLI settings in the container

Codex policy is baked at `/etc/codex/managed_config.toml` from
`config/codex-managed-config.toml`; its shared hook adapters are installed under
`/etc/codex/hooks/`. The config pins Sol/medium, loads the standard project
skills from `.agents/skills`, and renders a compact built-in footer with project,
branch, model/effort, context, quota, token, and run-state fields. Unlike
Claude's renderer, Codex's supported status line is a single ordered list rather
than an external multi-line command. System-managed Codex hooks are limited to
image-owned policy scripts; checkout-controlled status and formatter tasks stay
behind Claude/project trust instead of executing automatically at Codex startup.

## Terminal type and Ghostty terminfo

Ghostty sets `TERM=xterm-ghostty`. That name is correct on the machine running
Ghostty and unknown almost everywhere else, so on any system whose terminfo
database lacks the entry every ncurses program — `vim`, `less`, `htop`, `tmux`,
`zellij` — fails with "unknown terminal type" or renders with broken keys and
colours. Three places hit this; the container is the only one this repo can fix
for you.

**Inside the container — handled.** `.devcontainer/config/ghostty.terminfo` is
a checked-in copy of Ghostty's own entry (`infocmp -x xterm-ghostty`), and the
image build compiles it with `tic -x` before any shell exists — refresh it when
a Ghostty release changes the entry, since nothing here notices on its own. Like
the Claude policy above it lives in the **image**, so a volume wipe cannot take
it away, and it is a *required* config file — a missing `ghostty.terminfo` fails
the build rather than shipping a container that breaks only for Ghostty users. It earns its keep on every path
that actually carries your `TERM` inside — SSH forwards it by protocol, so a
`coder ssh` session lands as `xterm-ghostty` and resolves.

**Over SSH from the host — Ghostty's job, not this repo's.** Ghostty ships both
relevant SSH features **disabled** (1.3.1 defaults to
`no-ssh-env,no-ssh-terminfo`). Both ride on Ghostty's shell integration, so they
exist only where that loaded — the default `shell-integration = detect` covers
bash, zsh, fish, elvish, and nu; with it off, or in a shell it does not cover,
the key below is inert and neither feature runs.

**Start with `ssh-env` alone.** It costs nothing and cannot surprise you:

```text
shell-integration-features = ssh-env
```

It forwards `COLORTERM` and `TERM_PROGRAM` / `TERM_PROGRAM_VERSION` (subject to
the remote `sshd_config`'s `AcceptEnv`), and the wrapper starts every SSH
session at `xterm-256color` — a name every host resolves. Nothing is written to
the remote. Note that the downgrade is the wrapper's doing, not this feature's:
it starts there regardless and upgrades to `xterm-ghostty` only once the entry
is known to be present.

**Add `ssh-terminfo` only if you want full `xterm-ghostty` fidelity on remotes**,
and read this first:

```text
shell-integration-features = ssh-env,ssh-terminfo
```

- It installs Ghostty's terminfo into the remote's `~/.terminfo` on first
  connection, then caches the host so it happens once. It needs `infocmp`
  locally and `tic` on the remote.
- **The first `ssh host <command>` to an uncached host runs that command
  twice.** The wrapper appends its installer to your argument list and `ssh`
  joins the lot into one remote command line, so your command runs on the
  remote, the installer runs after it, and then the real session runs your
  command again. Traced against 1.3.1. A deploy, a migration, or anything else
  non-idempotent happens twice. Two things bound it — the wrapper exists only
  for `ssh` typed in an interactive Ghostty shell (scripts never see it), and
  connecting once interactively caches the host and avoids it — but that is a
  rule you have to remember for every new host. If you drive fresh hosts with
  one-shot remote commands, leave `ssh-terminfo` off and install the entry
  yourself.
- `ghostty +ssh-cache` lists and clears the cache; it is keyed on
  `user@hostname` (not the port), never expires, and a hit is trusted without
  re-checking — so a rebuilt host needs its entry cleared, and a Ghostty upgrade
  needs that *plus* replacing the entry the remote resolves, because the
  installer treats any existing `xterm-ghostty` as success and never re-runs
  `tic`.

Whichever you choose: features you leave out keep their defaults, so on a config that does not already
set the key, that one line is the whole change and `cursor`, `title`, and `path`
are untouched. If you *do* already set it, merge the two features into your
existing value rather than replacing it — whatever you drop reverts to its
default. For the same reason, do not paste the full list that
`ghostty +show-config --default` prints: it **pins** every feature in it,
`no-sudo` included, so a `sudo` you had deliberately enabled goes off.

**`docker exec` into some other container — nothing propagates the entry.** A
container not built from this repo's `config/` has no `xterm-ghostty`, and
neither `ssh-terminfo` nor the image build reaches inside it. `docker exec` does
not forward your `TERM` either — the process gets whatever the image or
container sets, or the daemon's `xterm` default under `-t` if nothing does — and
a `TERM=… docker exec` prefix changes only the client's environment. Ask for the
terminal you want with `-e`:
`docker exec -e TERM=xterm-256color -it <container> bash`.

## Persistent agent sessions (Herdr)

**Herdr** is the agent-session runtime in both profiles: it owns the panes your
coding agents run in and tracks each one's state (working / blocked / idle) so
you can see at a glance which agent is waiting on you. `zellij` and `tmux` are
still installed and still the right tool for general terminal multiplexing —
Herdr is not a replacement for them, it is the layer that knows what an *agent*
pane is doing.

The server **auto-starts on the first `herdr` invocation**. There is no `herdr
server start` subcommand to run first; to check whether a server is already
live, run `herdr status`.

To attach from another machine, SSH in and run `herdr` — with the caveat that
the SSH endpoint must execute **inside the devcontainer**, where this image
installed Herdr and configured its socket. An SSH server that terminates on the
Docker host attaches you to a host-side Herdr (or nothing at all). On Coder the
agent runs inside the workspace container, so `coder ssh <workspace>` lands in
the right place:

```bash
ssh <container-ssh-host>
herdr
```

or let Herdr do the SSH itself — it wraps `ssh`, so it uses whatever host alias
your SSH config defines (on Coder, `coder config-ssh` writes the
`coder.<workspace>` aliases). This form runs a local Herdr thin client, so
install Herdr on the machine you attach from first (`brew install herdr` on
macOS, or the installer at [herdr.dev](https://herdr.dev/)):

```bash
herdr --remote <container-ssh-host>
```

`~/.config/herdr` is a **named volume** (`herdr-config-…`, one per profile; on
Coder it is symlinked into the `~/.persistent` volume instead), so Herdr's own
state survives a rebuild: snapshot restore brings the workspace shape back —
tabs, panes, cwds, layout — as fresh shells. Whether an agent *conversation*
resumes inside its restored pane is a separate mechanism:
`resume_agents_on_restore` only works for agents whose Herdr integration has
recorded a native session reference. post-create installs the Claude Code and
Codex integrations automatically (`herdr integration install`, idempotent) —
Gemini has no resume integration in v0.8. The
conversations themselves persist regardless, in the `~/.claude`, `~/.codex`,
and `~/.gemini` volumes, so a pane that restores as a plain shell can still
resume its agent by hand (e.g. `claude --resume`).

The default session's server socket deliberately does **not** live in that
volume. The image sets `HERDR_SOCKET_PATH=/tmp/herdr.sock` container-wide, so a
socket left behind by a dead server cannot ride along in the persisted config
directory into the next container. (Herdr derives the client socket from the
same variable — `/tmp/herdr-client.sock`.) Named sessions (`herdr --session`)
ignore that override and keep sockets under `~/.config/herdr/sessions/<name>/`,
so a stale named-session socket can survive a rebuild — harmless, but if a
named session misbehaves after a rebuild, delete its `herdr.sock` and reattach.

## Secrets — 1Password Environments (the standard)

Don't hand-write or copy `devcontainer.env`. The standard is **1Password
Environments**, which mounts a virtual `.env` over a UNIX pipe — the values are
**never written to disk or committed** (the path is gitignored anyway).

1. In the **1Password** app → **Developer** → **Environments**, create an
   environment for this repo (import an existing `.env` or add the variables
   below, each referencing a vault item).
2. Set the destination to **Local .env file** and point the mount at
   `.devcontainer/devcontainer.env` (bot). Add a second destination at
   `.devcontainer/dev/devcontainer.env` for the dev profile.
3. Authorize access when prompted. The container's `--env-file` then reads it
   like any `.env`.

Variables per profile:

| Variable | Bot | Dev | What it's for |
|---|---|---|---|
| `GH_TOKEN` | ✅ | — | the **bot's** `gh` CLI / API (dev logs in as you instead) |
| `CLAUDE_CODE_OAUTH_TOKEN` | ✅ | ✅ | Claude Code |
| `AGENT_DECK_TELEGRAM_KEY` | ✅ | ✅ | agent-deck bridge (optional) |
| `TS_AUTHKEY` | — | ✅ | Tailscale (dev only) |
| `KIMI_API_KEY` / `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, `QWEN_API_KEY` | ✅ | ✅ | alt-model wrappers (opt-in: `use_alternative_claude_providers`) |

`ANTHROPIC_API_KEY` is deliberately **forbidden** — it silently overrides
`CLAUDE_CODE_OAUTH_TOKEN`, so `init-env.sh` strips it from the env-file.

### Operator GitHub login (dev profile)

The dev profile ships no `GH_TOKEN`, so `gh` and `git` are unauthenticated until
you log in as yourself:

```sh
gh auth login --hostname github.com --git-protocol https \
  --web --scopes "workflow,project"
gh auth setup-git
```

`--scopes` is *additive* to gh's defaults (`repo`, `read:org`, `gist`). `project`
is what Projects V2 writes need — without it `task status:gh` reports the board
as unreachable — and `workflow` lets you edit `.github/workflows/`, which the bot
is deliberately denied. `--web` opens a browser when there is one and otherwise
prints a device code, so it works over a plain terminal. `gh auth setup-git` is
the separate step that bridges the login into git's credential helper; the
`post-create` that normally does it has already run by the time you log in, so
run it yourself.

The profile also blanks `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN`, and
`GITHUB_ENTERPRISE_TOKEN` in `containerEnv`. `gh`'s credential precedence runs
`GH_TOKEN` → `GITHUB_TOKEN` → the enterprise names → your stored login, so
dropping only the first would hand the container to whichever alias an env-file
happened to carry — silently, and as the wrong identity. An empty value reads as
unset, and `containerEnv` outranks the env-file.

Those three names are therefore **reserved** in the dev profile. The blank
reaches every process, not just `gh`, so an application in this container that
reads `GITHUB_TOKEN` at runtime gets an empty string and needs a different
variable name. That is the deliberate trade: one container cannot let the same
name mean both "who `gh` is" and "the app's credential", and in the profile whose
defining property is its GitHub identity, `gh`'s meaning wins. Note this is the
*runtime* value only — the env-file keeps whatever it held; blanking shadows it
rather than deleting it, which is why this is not done by evicting the names in
`init-env.sh` (that would destroy the value in **both** profiles' env-files).

**You will do this again after every rebuild.** `~/.config/gh` is on no volume —
[architecture/security.md](../architecture/security.md) explains why that is the
trade rather than an oversight.

If you find yourself logging in far more often than you rebuild, the problem is
not the missing volume — it is that something is **recreating** the container
behind your back. Chase that instead; see
[Attach paths and container managers](#attach-paths-and-container-managers).

Nothing fails hard before you log in. `post-create` prints the commands above and
sibling repos are skipped with a warning (re-run
`bash .devcontainer/scripts/bootstrap-related-repos.sh` afterwards). What does
not work is anything that talks to GitHub *as you*: `git push`, `gh pr`,
`gh api`.

Under **VS Code Remote-Containers** this differs in mechanism, not identity:
`post-create-common.sh` unsets the in-container gh credential helpers and lets
VS Code forward the host's, so *git* already acts as you on attach while `gh`
still needs its own login. Run `gh auth login` there but **not**
`gh auth setup-git` — re-adding the helper fights the one VS Code manages, which
is why post-create unset it. On Coder and the plain CLI, where nothing else
manages git's credential, both commands apply.

**If an org restricts third-party OAuth apps** (or enforces SAML SSO), the GitHub
CLI app needs that org's approval before your login reaches its repos. Approving
the app is the fix. Where an org genuinely cannot, the fallback is
`gh auth login --with-token` with an SSO-authorized **classic** PAT — not a
fine-grained one. A fine-grained PAT has exactly one resource owner, so using one
here would reintroduce the single-org ceiling this arrangement exists to remove.

### Alternative model providers (`claude-kimi` / `claude-deepseek` / `claude-glm` / `claude-qwen` / `claude-qwen-local`)

Opt in with the `use_alternative_claude_providers` Copier answer (default off;
asked only when `devcontainer=true`) to ship the `claude-kimi`, `claude-deepseek`,
`claude-glm`, `claude-qwen`, and `claude-qwen-local` shell functions. The hosted
four mirror the equivalent host wrappers: each launches `claude` in a subshell
with `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` pointed at a provider's
native Anthropic-compatible endpoint under a vendor-documented path prefix
(Moonshot Kimi K3, DeepSeek V4, Z.AI GLM-5.2, Alibaba DashScope Qwen3.7-Max /
Qwen3-Coder-Plus — no proxy), plus the per-tier `ANTHROPIC_*_MODEL` vars
(`claude-qwen` uses Qwen3.7-Max for the main/reasoning roles and
Qwen3-Coder-Plus for coding/subagent roles). The functions live in
`.devcontainer/config/claude-providers.sh` and are sourced from `shell-aliases.sh`.

`claude-qwen-local` is different: it targets your **own** Ollama/LM Studio
endpoint serving `qwen3-coder:30b`, so it needs no API key and no
1Password entry — `ANTHROPIC_AUTH_TOKEN` is a meaningless placeholder value.
Its default `ANTHROPIC_BASE_URL` has **no** path suffix (`http://<host>:11434`,
not `.../anthropic`) — unlike the hosted providers, Ollama and LM Studio serve
their Anthropic-compatible API from the server root, and the client already
appends the API path itself. The default host is chosen at launch: it probes
`host.docker.internal` (which both shipped devcontainer profiles map to the
host gateway via `runArgs`, so it resolves even on native Linux) and falls
back to `localhost` when that name doesn't resolve — set `QWEN_LOCAL_BASE_URL`
to override either guess. **On native Linux, the DNS mapping alone is not
enough**: stock Ollama binds `127.0.0.1:11434` (loopback-only), so it refuses
the container's connection regardless. Do **not** bind `0.0.0.0` — Ollama has
no auth, so that exposes it to the whole LAN. Instead set
`OLLAMA_HOST=<docker0-bridge-IP>` (`ip addr show docker0`, typically
`172.17.0.1`) to scope it to the Docker bridge, firewall port `11434` to that
bridge if it must stay on `0.0.0.0` for other reasons, or point
`QWEN_LOCAL_BASE_URL` at an endpoint that's already reachable.

The provider API keys flow through the same env-file pipeline as everything else
(`init-env.sh` allow-list → `devcontainer.env` → `--env-file`), so add them to your
1Password Environments mount. **Both profiles** receive the keys when opted in. The
bot runs `bypassPermissions`, so be aware a headless agent in the bot can read them —
this is a deliberate extension of the bot's posture, not an oversight. The wrappers
themselves are interactive (you type `claude-glm`); a default `agent-deck`/foreman
launch still invokes plain `claude`.

Two container-specific details differ from the host wrappers:

- Each wrapper `unset`s `CLAUDE_CODE_OAUTH_TOKEN` in its launch subshell (in addition
  to `ANTHROPIC_API_KEY`). The container sets the OAuth token via its env-file; left
  set, it would compete with the provider's `ANTHROPIC_AUTH_TOKEN`. Unsetting it
  guarantees the provider auth wins for that launch only.
- The `op run` key fallback (used when the env var is absent) re-sources the
  image-baked `/usr/local/share/devcontainer-config/claude-providers.sh`, not
  whatever host file defines the equivalent functions. It works only in the dev
  profile (the bot has no
  1Password CLI); in the bot the env-file is the only key source.

### What `init-env.sh` does

On container init the devcontainer runs `.devcontainer/scripts/init-env.sh` on
the **host**. It enforces the per-profile allow-list (e.g. evicts `TS_AUTHKEY`
and `ANTHROPIC_API_KEY` from the bot env-file, and `GH_TOKEN` from the dev one,
on every rebuild) and, in
environments where the 1Password app isn't present (**Coder / Codespaces**),
captures the same variables from the **host environment**, where they arrive as
workspace/template parameters. It does **not** call `op` itself — 1Password
Environments is what supplies the values locally.

A variable already in the env-file but absent from the host env is **left
alone** — that is how a 1Password-managed value survives a rebuild when you
haven't also exported it in your shell.

If a variable is missing from **both** places, though, nothing will supply it,
and `init-env.sh` prints a warning to stderr naming the variables (never their
values) in the container-build log:

```text
init-env.sh: warning: allow-listed but unset in the host env and absent from .devcontainer/dev/devcontainer.env:
init-env.sh:   TS_AUTHKEY
init-env.sh: the container will start without them. On Coder/Codespaces set them as
init-env.sh: workspace/repo secrets; locally populate the env-file from 1Password.
```

The build still succeeds — a missing optional secret must not block a rebuild,
and `initializeCommand` runs on the host, where a non-zero exit aborts the whole
build. So this is a signal to read, not a failure. Without it the container comes
up clean and only the dependent step fails later, far from the cause: a missing
`TS_AUTHKEY` went unnoticed for hours in a Coder workspace that way.

The warning covers **only** the vars this profile's allow-list permits, so the
bot profile never reports `TS_AUTHKEY` missing. Its absence there is correct —
that profile has no tailnet path at all — and naming it would advertise a
credential the bot container must never hold.

## Run it in Coder

The devcontainers are Coder-ready: the `CODER` env is passed through, the
`config/` tree is baked to `/usr/local/share/devcontainer-config/` so it
survives Coder's `/tmp` mount shadowing, and `init-env.sh` reads secrets from
the host environment (above).

What Coder needs is a **workspace template** that clones this repo and builds the
devcontainer — that template is **org-level infrastructure, not part of this
repo** (one template serves every repo). To stand this repo up in Coder:

1. Use your org's Coder "devcontainer" template (the canonical example is
   `terraform/coder/devcontainer/` in
   [harmonops/harmon-infra](https://github.com/harmonops/harmon-infra)). It uses
   the Coder `git-clone` + `devcontainers-cli` modules.
2. Create a workspace from it and set the parameters:
   - **repo** → `https://github.com/evanharmon1/harmon-devkit`
   - secrets → `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`, and
     `GH_TOKEN` **for a bot workspace only** — a dev workspace runs
     `gh auth login` instead
     (+ `TS_AUTHKEY` if you want Tailscale); `KIMI_API_KEY`/`MOONSHOT_API_KEY`,
     `DEEPSEEK_API_KEY`, `ZAI_API_KEY`, `QWEN_API_KEY` for the alt-model wrappers
     (`claude-qwen-local` needs no key — see below). Coder passes these
     into the workspace's host environment, where `init-env.sh` picks them up.

   Coder is the case where this matters most: there is no 1Password app in the
   workspace, so a **workspace parameter is the only way a secret arrives**. A
   parameter you forget to set is not backfilled from anywhere — the env-file
   starts empty on a fresh workspace, so the variable is simply absent. Check
   the build log for the `init-env.sh: warning:` lines above before assuming a
   workspace is fully provisioned; they name exactly what did not arrive. On a
   **rebuild** of an existing workspace the env-file may still hold a value from
   an earlier build, which is why the warning fires only when both sources are
   empty.
3. The build pulls `ghcr.io/evanharmon1/harmon-devkit-devcontainer` from GHCR as a cache. If that
   package is private, give the Coder builder a read token (or make the package
   public); a cache miss only makes the first build slower.

> This repo's `Dockerfile` is a thin overlay on the **public** shared
> `ghcr.io/evanharmon1/harmon-devcontainer` toolchain image (pinned by
> immutable `tag@digest`), so no registry credential is needed for the base —
> only the repo's own `-devcontainer` cache image matters.

## Attach paths and container managers

**Two different managers can attach VS Code to the same dev container**, and
they are not interchangeable:

| Manager | How you start it | `REMOTE_CONTAINERS` | `devcontainer.json` `customizations.vscode` |
|---|---|---|---|
| **Dev Containers extension** | "Dev Containers: Reopen in Container" | `true` | applied |
| **Coder devcontainer integration** | the Coder UI **VS Code** button, or the `coder` CLI | unset | **not** applied |

That second row is the one that surprises people. A Coder-attached window is a
perfectly good shell in the right container, but nothing in
`customizations.vscode` reached it — settings, and the extension list, are
whatever your Coder-side configuration provides. `post-create-common.sh` already
branches on `REMOTE_CONTAINERS` for the git-credential handling, so the two
paths differ in mechanism even where they agree on identity.

**Standardize on the Dev Containers extension path.** It builds from the current
checkout and applies `customizations.vscode`, so what you attach to matches what
the repo says; the Coder button is a fallback that reattaches to whatever
container already exists, however old the image it was built from. Alternating
between the two flips you between a fresh container and a stale one, and the
symptoms are content-level — an older starship prompt, a retired statusline —
which read as client-side rendering faults and get diagnosed as such. The tell
is the staleness warning: `post-start` and the `Environment` section of
`task status` both run `.devcontainer/scripts/check-image-staleness.sh`, which
diffs the image-baked `/usr/local/share/devcontainer-config/` against
`.devcontainer/config/` and prints `image is stale: N baked configs differ from
the checkout — rebuild the container` when they have drifted. It is warn-only
and silent when clean, so seeing it at all means rebuild rather than debug.

### The standard flow, step by step

Coder is still how you reach the workspace **host** — the split above is only
about which layer makes the *container* hop. The extension path, concretely:

1. **Connect to the workspace itself** (Coder UI button or "Coder: Open
   Workspace"). If the picker offers both the workspace and a
   `devcontainer` sub-agent target, choose the **workspace** — the sub-agent
   target is exactly the Coder-direct hop the table above warns about.
2. In that host window: **File → Open Folder** → the repo checkout on the
   host.
3. VS Code detects `.devcontainer/` and offers **"Reopen in Container"** —
   accept it (or run "Dev Containers: Reopen in Container" from the palette).
   When it asks which config, pick the **dev profile**
   (`.devcontainer/dev/devcontainer.json`) for interactive work; the root
   config is the bot profile.
4. **Every reattach after that is one click**: File → **Open Recent** — the
   entry reading `<repo> [Dev Container: DEV — …]` replays the whole nested
   route (Coder → extension → container) correctly. This is the reattach
   path; the Coder button is not. `scripts/open-devcontainer.sh <repo-match>`
   is the same click from a terminal: it lifts the matching `dev-container+…`
   folder URI out of VS Code's own recents and runs `code --folder-uri` (no
   argument lists what is on offer, each line ending in a short `[token]` to
   pass instead of a name when two profiles of one checkout read alike). It
   belongs on the **client**, which is where that recents database and `code`
   are — this checkout is on the workspace host, so copy the script to the
   client once rather than running it over SSH against the wrong machine's
   state; it is deliberately self-contained, so a copy is all it takes:

   ```sh
   mkdir -p ~/bin
   scp <workspace-host>:<checkout>/scripts/open-devcontainer.sh ~/bin/open-devcontainer
   chmod +x ~/bin/open-devcontainer
   ```

   Copying from your own checkout — not `curl`ing a branch — is deliberate:
   it installs exactly the reviewed version sitting next to the docs you are
   reading, where a download from a moving branch would fetch whatever it
   has become since.

   Then wrap the installed copy in whatever your fingers already reach for —
   `alias devbox='~/bin/open-devcontainer <repo-match>'`, a Raycast script
   command, a Shortcuts action — remembering that it can only replay an entry
   that exists, so step 3 is still how a repo gets its first one.
5. **Rebuilds** happen from the same window: "Dev Containers: Rebuild
   Container".

**Which path a window used is written in its bottom-left corner.** The remote
indicator reads `Dev Container: DEV — …` in an extension-attached window and
`Coder: <workspace>` (or the bare workspace name) in a Coder-direct one — a
glance answers it before any terminal is opened. The shell-level check agrees:
`echo $REMOTE_CONTAINERS` prints `true` only on the extension path. One caveat: the two managers each
keep their own container generation, so after adopting this flow, remove any
old Coder-managed container on the host (`docker ps -a`, then `docker rm -f`
the stale one and `docker rmi` its image) — until then the Coder button keeps
serving it, and only the staleness warning will tell you.

Triage a suspect window with one line:

```sh
hostname; echo "RC=$REMOTE_CONTAINERS CODER=$CODER LANG=$LANG"; readlink -f ~/.claude.json
```

- `hostname` — which container you are actually in. A window attached to the
  *wrong* target is the failure that looks like everything else.
- `RC=` / `CODER=` — which manager attached you, per the table above.
- `LANG=` — an empty or `POSIX` value is the usual cause of mangled glyphs and
  sort order.
- `readlink -f ~/.claude.json` — must resolve to `~/.claude/.claude.json`. If it
  resolves to itself, the symlink is missing and Claude Code state is **not**
  being persisted.

### Silent recreation

A "reattach" can silently **recreate** the container rather than reconnect to
it: `postCreateCommand` runs again, and anything not on a named volume is gone.
Two managers watching one workspace makes this more likely, and a config file
whose mtime changes on every connect is enough to trigger it — Coder's
integration reads a changed `devcontainer.env` as a dirty config. That is why
`scripts/init-env.sh` is **idempotent**: it composes the new env-file content in
a temp file, compares it, and skips the write entirely when nothing changed, so
an unchanged file keeps its mtime.

Recognizing a recreation after the fact:

- fresh mtimes on `~/.zshrc` and `~/.bashrc` (post-create rewrote the source
  lines);
- exactly one log directory under `~/.vscode-server/data/logs/` — a
  long-running container accumulates several;
- `gh auth status` in the **dev** profile reporting no login. This is the most
  visible symptom, and the easiest to misread: `~/.config/gh` is deliberately on
  no volume, so re-authenticating after a *genuine* rebuild is the intended cost
  — but re-authenticating when you did not rebuild anything is this bug, not that
  trade;
- anything under `~/` that is not on a named volume reverted to image defaults.

Nothing here is data loss by design: agent state, shell history, and zoxide data
all sit on named volumes precisely so a recreation is survivable, and
`~/.claude.json` is symlinked onto one for the same reason (below). What is lost
is container-local scratch — and, in `dev/`, the `gh` login, which is on no
volume by decision rather than by omission (see
[architecture/security.md](../architecture/security.md)). That makes the login a
useful **canary**: a re-auth prompt you did not expect is the cheapest signal
that a recreation happened. The fix for re-authenticating too often is to stop
the silent recreations, not to persist a plaintext token.

If the prompt draws boxes or run-together segments in a Coder-attached window,
that is the client-side Nerd Font issue in
[troubleshooting.md](troubleshooting.md), not a container fault: the font must be
set at **user** scope on the client, because a Coder window never applies the
devcontainer's `customizations.vscode` and we deliberately do not ship
`terminal.integrated.fontFamily`.

### Why `~/.claude.json` is a symlink

Claude Code keeps account and session state — the OAuth account, subscription
linkage, remote-control registration, per-project history — in `~/.claude.json`,
which sits in the home directory, **outside** the persisted `~/.claude/` volume.
The lifecycle therefore symlinks `~/.claude.json` → `~/.claude/.claude.json` so
that state lands on the volume.

The migration is deliberately non-destructive
(`.devcontainer/scripts/link-claude-json.sh`), and the failure it prevents is
worth knowing. Anything that launches `claude` *before* the symlink exists makes
Claude Code write a fresh, near-empty **real** file at `~/.claude.json` — little
more than a trust-dialog acceptance. Post-start then used to `mv` that stub over
the persisted copy, so a container recreation logged you out, dropped plan
detection to usage credits, and broke remote-control session resume. The helper
now runs **early** in post-create, before anything that can spawn `claude`, and
the volume copy always wins: a stray file is deep-merged *into* it (contributing
only keys the volume lacks), and if it cannot be merged safely it is parked
beside the volume copy as a timestamped `.bak` rather than either side being
lost. `readlink -f ~/.claude.json` above is the one-second check that it worked.

## Working on related repos

To work across several repos in one container, list them in
`.devcontainer/related-repos.txt` (one `owner/repo` per line; `@branch`, full
URLs, and ssh URLs also work — ssh URLs are rewritten to https by the
environment gitconfig baked into the image at `~/.config/git/config`, so
in-container git operations never depend on an SSH agent). They are:

- **cloned** into `/workspaces/`, beside this repo, on container **create**
  (`scripts/bootstrap-related-repos.sh`) — so a rebuilt or persistence-lost
  container re-populates them;
- **fetched** non-destructively on container **start**
  (`scripts/fetch-related-repos.sh`).

Both are safe to re-run: an already-cloned sibling is **never clobbered** —
clone skips it, and start runs `git fetch` only (never pull / merge / checkout),
so uncommitted work, local commits, and the checked-out branch stay put. The
list is preserved across `copier update` (an empty list is a no-op).

To let Claude read and search the cloned siblings, add them to
`.claude/settings.json` in **two** places — `permissions.additionalDirectories`
(Claude's own Read/Grep/Glob tools) and `sandbox.filesystem.allowRead` (the Bash
sandbox):

```json
{
  "permissions": {
    "additionalDirectories": ["../sibling-repo"]
  },
  "sandbox": {
    "filesystem": {
      "allowRead": ["../sibling-repo"]
    }
  }
}
```

## See also

- [architecture/security.md](../architecture/security.md) — full secret strategy.
- [troubleshooting.md](troubleshooting.md) — devcontainer issues.
- `.github/workflows/devcontainer-build.yml` — the GHCR prebuild.
