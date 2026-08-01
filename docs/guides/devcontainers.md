# Devcontainers

Harmon DevKit ships a **dual-profile** devcontainer. Both profiles share
one `Dockerfile` and the baked `.devcontainer/config/` tree; they differ in
which secrets and capabilities they allow.

| Profile | Path | For | Tailscale |
|---|---|---|---|
| **Bot** | `.devcontainer/devcontainer.json` | AI agents (Claude Code, Codex, Gemini) | no |
| **Dev** | `.devcontainer/dev/devcontainer.json` | humans | yes (`TS_AUTHKEY`, `--device=/dev/net/tun`) |

The bot profile intentionally omits `TS_AUTHKEY` from its allow-list so a tailnet
key never reaches an agent container.

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

`config/claude-statusline.sh` renders a two-line status line matching the one a
host session shows:

```text
📁 ~/git/harmon-devkit  🌿 main  🤖 Opus 5  📟 v2.1.220  🎨 default
🧠 Context Remaining: 60% [======----]
```

To use your own instead, point `statusLine.command` in `~/.claude/settings.json`
at it — the seed merge will not overwrite it.

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
| `GH_TOKEN` | ✅ | ✅ | `gh` CLI / API |
| `CLAUDE_CODE_OAUTH_TOKEN` | ✅ | ✅ | Claude Code |
| `AGENT_DECK_TELEGRAM_KEY` | ✅ | ✅ | agent-deck bridge (optional) |
| `TS_AUTHKEY` | — | ✅ | Tailscale (dev only) |

`ANTHROPIC_API_KEY` is deliberately **forbidden** — it silently overrides
`CLAUDE_CODE_OAUTH_TOKEN`, so `init-env.sh` strips it from the env-file.

### Opting in to Fable 5 (`DEVCONTAINER_FABLE_CONSENT`)

Fable 5 needs a one-time "draws from usage credits" consent, and Claude Code
stores it **per machine** in `~/.claude.json` (`.fableOverageConsentV2`, keyed
by your account's org UUID). `~/.claude` is a container-local volume, so the
consent you granted on your host never reaches a dev container — and without
it Fable can end up **unselectable in `/model`** here while working fine on
the host, on an account that is entitled to it.

`config/claude-hooks/seed-fable-consent.sh` records it for the signed-in
account, from postStart (covers restarts) and from interactive shell startup
(covers the first login on a fresh volume, when no account exists yet at
postStart time).

It deliberately does **not** run from inside Claude Code. The CLI caches
`.claude.json` in memory at startup and never re-reads it, so a write from
within a session cannot affect that session — and the CLI's next config write
serializes its stale copy back over the file, dropping the record. Writing
between sessions is what makes it both visible and durable. The honest
residual: on a brand-new container the **first** authenticated session still
cannot select Fable, because the account it is keyed to does not exist until
that session authenticates. Every session after it can, with no restart.

It is **off unless you opt in**, because the flag is a
billing authorization and the hook is image-baked — it would otherwise grant
it silently for whichever account signs in, including in repos templated from
here. Set it for your own account only:

```sh
DEVCONTAINER_FABLE_CONSENT=true
```

Add it to your 1Password Environment alongside the variables above (it is not
a secret, but that is what generates the env-file). It is not in
`ALL_MANAGED_VARS`, so `init-env.sh` leaves it alone.

**Keep it out of `containerEnv`.** That lives in the checked-in
`devcontainer.json`, which is templated downstream by harmon-init — setting it
there would grant the billing consent for whichever account signs into that
profile, in every repo built from it, which is the exact thing the opt-in
gate exists to prevent. This is why it is unlike `DEVCONTAINER_TAILSCALE`,
which is a per-profile capability switch rather than an authorization. The
opt-in must stay with the account owner: the gitignored env-file, or an
explicit local override you do not commit.

To revoke: delete the `fableOverageConsentV2` key from
`~/.claude/.claude.json` and unset the variable.

### What `init-env.sh` does

On container init the devcontainer runs `.devcontainer/scripts/init-env.sh` on
the **host**. It enforces the per-profile allow-list (e.g. evicts `TS_AUTHKEY`
and `ANTHROPIC_API_KEY` from the bot env-file on every rebuild) and, in
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
   - secrets → `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_DECK_TELEGRAM_KEY`
     (+ `TS_AUTHKEY` if you want Tailscale). Coder passes these into the
     workspace's host environment, where `init-env.sh` picks them up.
3. The build pulls `ghcr.io/evanharmon1/harmon-devkit-devcontainer` from GHCR as a cache. If that
   package is private, give the Coder builder a read token (or make the package
   public); a cache miss only makes the first build slower.

> Unlike harmon-infra, this repo's `Dockerfile` uses the **public** Microsoft
> base image, so the classic-PAT / private-base-image (`ghcr_read_token`)
> complication does not apply here — only the repo's own `-devcontainer` cache
> image matters.

## Working on related repos

To work across several repos in one container, list them in
`.devcontainer/related-repos.txt` (one `owner/repo` per line; `@branch`, full
URLs, and ssh URLs also work — ssh URLs are rewritten to https by the
container gitconfig, which `post-create-common.sh` sets up so in-container
git operations never depend on an SSH agent). They are:

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
