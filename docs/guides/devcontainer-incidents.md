# Devcontainer incidents

Worked diagnoses of real failures in this devcontainer, and where the shipped
fix for each lives. Every one is already handled by the scripts in
`.devcontainer/` — this exists so that when something *looks* like one of these,
you can tell quickly whether the guard failed or you have found something new.

For everyday problems see [troubleshooting.md](troubleshooting.md); this file is
the deep end.

## The conductor and Telegram bridge do not start

**Symptom.** After launching the container, the agent-deck conductor reports
"stopped", and Telegram messages to the bot get no reply or return errors.

This was one visible symptom with five independent causes, all of which had to
be fixed before it worked reliably on Coder. That matters diagnostically: fixing
one and still seeing "stopped" does not mean the fix was wrong.

### 1. A missing `pnpm` kills every later lifecycle command

Node is installed from NodeSource, but without `corepack enable pnpm` the
`postCreateCommand` fails at `pnpm install` with exit 127 — and
`@devcontainers/cli` then **skips all remaining lifecycle commands**, including
`postStartCommand`. The conductor never starts, and the error you see is about
pnpm, not about the conductor.

Shipped fix: `corepack enable pnpm` in the Dockerfile's Node layer.

**Generalize this one.** Any non-zero exit in `postCreateCommand` silently
cancels `postStartCommand`. If a start-time service is mysteriously absent,
read the *create* log before investigating the service.

### 2. A status grep matched the wrong process

The conductor start was guarded by `! grep -qi "running"` over
`conductor status`, which also matched the *bridge's* "RUNNING" line — so the
conductor block was skipped whenever the bridge was up.

Shipped fix: grep for `"stopped"` specifically, and start the conductor before
the bridge.

Case-insensitive greps over multi-service status output are a recurring trap;
match the service you mean, not a word that appears somewhere in the output.

### 3. A stale token survived a rebuild

`init-env.sh` skipped secrets already present in `.devcontainer/devcontainer.env`.
On Coder that file lives on the home volume and persists across rebuilds, so a
token rotated in the workspace parameters was ignored in favour of the old value.

Shipped fix: delete-then-append, so host environment always wins; plus token
re-injection in `postStartCommand` so a change takes effect without a rebuild.

### 4. `ModuleNotFoundError: No module named 'toml'`

The Dockerfile installs `toml` and `aiogram` for the **system** Python, but the
devcontainer Python feature installs its own and takes over `python3` on PATH.
The bridge therefore starts once on the Dockerfile's Python and crashes on
restart under the feature's.

Shipped fix: `pip install --quiet toml aiogram` in `post-create-common.sh`,
which runs *after* features are installed.

**Generalize this one too.** Anything the Dockerfile installs into a runtime a
devcontainer feature later replaces must be reinstalled post-create.

### 5. Coder rebuilds reused a stale checkout

Coder's git-clone module clones only at workspace creation. Rebuilding the
container reuses the old checkout, so merged fixes to the Dockerfile or
lifecycle scripts are not applied — and you debug code that is not running.

Shipped fix: a fast-forward pull of `origin/main` in `initializeCommand`, guarded
to run only on a clean main branch.

## Claude Code demands a fresh login after every rebuild

**Symptom.** `claude auth status` reports logged in and `claude -p "hi"` works,
but launching `claude` interactively forces a full OAuth flow again.

The split between working headless and broken interactive is the clue: the
credentials are fine, the *session state* is missing.

### 1. Volume names that change with the image

Mounts keyed on `${devcontainerId}` hash the container image, so **every
Dockerfile edit mints new empty volumes** — losing Claude auth, shell history,
and agent-deck config together.

Shipped fix: key the volumes on the rendered `<github_org>-<project_slug>`,
plus a `-dev` suffix on the human profile. That name has to satisfy three
constraints at once, and missing any one of them has bitten this repo:

- **Stable across image changes**, or every Dockerfile edit discards state —
  the failure above.
- **Distinct per profile.** The bot profile deliberately omits `TS_AUTHKEY` and
  has no 1Password feature; if both profiles shared `.claude`, a bot container
  could read credentials a human authenticated in the dev profile.
- **Distinct per repository.** Local Docker volumes are global to the daemon,
  not scoped to a checkout. Keying on the directory basename alone means two
  clones sharing a name — `~/git/harmon-init` and
  `~/git/orgs/other-org/harmon-init`, say — share credential volumes. That is
  not hypothetical; it is the normal shape of an org-scoped checkout layout.

`${devcontainerId}` satisfies the last two but fails the first. The basename
satisfies the first but fails the last. `<github_org>-<project_slug>` plus a
profile suffix satisfies all three, and Coder's per-workspace
Docker-in-Docker makes it a non-issue there regardless.

Changing the scheme costs one final state loss, since the new volume names
start empty. After that, rebuilds preserve state.

If several kinds of persisted state vanish at once, suspect the volume identity,
not the individual tools.

### 2. `~/.claude.json` sits outside the persistent volume

Interactive session state lives in `~/.claude.json` — the home directory, *not*
the `~/.claude/` volume. Credentials in `~/.claude/.credentials.json` survive, so
headless keeps working while the TUI re-prompts.

Shipped fix: `post-start-common.sh` symlinks `~/.claude.json` into the persistent
`~/.claude/` volume, and `post-create-common.sh` seeds it with
`hasCompletedOnboarding` on an empty volume. Expect one more login the first
time this applies; rebuilds after that keep state.

## A recreated Coder workspace reuses stale volumes

**Symptom.** Deleting a Coder workspace and recreating it with the same name
yields an old git branch and outdated config.

**Cause.** `lifecycle { prevent_destroy = true }` on the persist volume makes
`terraform destroy` fail, orphaning every Docker volume for that workspace —
home, docker, persist, and the devcontainer named volumes.

This one is **infrastructure, not this repo**: the fix is removing
`prevent_destroy` from the volume resource in the Coder devcontainer template.

## Diagnostics

```bash
# The lifecycle scripts name the conductor after the CHECKOUT DIRECTORY
# (post-start-common.sh: REPO_NAME="$(basename "$PWD")"), which is not
# necessarily the project slug — derive it the same way rather than guessing.
REPO_NAME="$(basename "$PWD")"

# conductor, bridge, notifier
agent-deck conductor status "$REPO_NAME"

# devcontainer start log — read this FIRST for anything start-related
cat /tmp/devcontainer-post-start.log

# Telegram bridge
tail -30 ~/.agent-deck/conductor/bridge.log

# Claude credentials (headless path)
claude auth status

# prove the persistent volume is actually mounted
cat /proc/self/mountinfo | grep claude

# attach to the conductor session to watch prompts (Ctrl+B d detaches)
agent-deck session attach "conductor-$REPO_NAME"
```
