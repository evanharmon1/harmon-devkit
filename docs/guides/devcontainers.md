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
| Hook scripts | `/etc/claude-code/hooks/` (image) | `config/claude-hooks/` | no |
| Status line | `/etc/claude-code/statusline.sh` (image) | `config/claude-statusline.sh` | yes |
| User defaults | `~/.claude/settings.json` (**volume**) | `config/claude-user-defaults.json` | yes |

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

### What `init-env.sh` does

On container init the devcontainer runs `.devcontainer/scripts/init-env.sh` on
the **host**. It enforces the per-profile allow-list (e.g. evicts `TS_AUTHKEY`
and `ANTHROPIC_API_KEY` from the bot env-file, and `GH_TOKEN` from the dev one,
on every rebuild) and, in
environments where the 1Password app isn't present (**Coder / Codespaces**),
captures the same variables from the **host environment**, where they arrive as
workspace/template parameters. It does **not** call `op` itself — 1Password
Environments is what supplies the values locally.

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
     (+ `TS_AUTHKEY` if you want Tailscale). Coder passes these
     into the workspace's host environment, where `init-env.sh` picks them up.
3. The build pulls `ghcr.io/evanharmon1/harmon-devkit-devcontainer` from GHCR as a cache. If that
   package is private, give the Coder builder a read token (or make the package
   public); a cache miss only makes the first build slower.

> This repo's `Dockerfile` is a thin overlay on the **public** shared
> `ghcr.io/evanharmon1/harmon-devcontainer` toolchain image (pinned by
> immutable `tag@digest`), so no registry credential is needed for the base —
> only the repo's own `-devcontainer` cache image matters.

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
