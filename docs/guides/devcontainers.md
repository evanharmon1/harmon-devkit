# Devcontainers

Harmon DevKit ships a devcontainer in **three postures**. All three share
one `Dockerfile` and the baked `.devcontainer/config/` tree; they differ in
which secrets and capabilities they allow.

| Profile | Path | For | GitHub auth | Tailscale |
|---|---|---|---|---|
| **Bot** | `.devcontainer/devcontainer.json` | AI agents (Claude Code, Codex, OpenCode, Antigravity, Copilot CLI, pi, oh-my-pi) | the bot's PAT via `GH_TOKEN` | no |
| **Dev** | `.devcontainer/dev/devcontainer.json` | humans | the operator's own `gh auth login` | yes (`TS_AUTHKEY`, `--device=/dev/net/tun`) |
| **Agent** | `.devcontainer/agent/devcontainer.json` | unattended agents (Claude Code, Codex only) | the agent's own PAT via `AGENT_GH_TOKEN` | no — and egress is allowlisted |

Each profile authenticates as the identity it commits as, and the omissions are
what make that true: the bot profile leaves `TS_AUTHKEY` off its allow-list so a
tailnet key never reaches an agent container, and the dev profile leaves
`GH_TOKEN` off so a bot credential never reaches a human one.

**Codex follows the same split.** Both profiles default to `gpt-6.1-sol` with
medium reasoning and a 64 KiB project-instruction budget. The **dev** profile
uses `workspace-write`, `on-request`, and Auto-review: the sandbox defines the
writable boundary, while eligible exits from it are reviewed automatically.
The **bot** changes the managed config to `danger-full-access` plus `never`, so
there is no nested sandbox or interactive prompt inside Docker. Repository
instructions, hooks, GitHub token scope, mounted volumes, and Docker itself
remain the bot's boundaries.

## Bot-only agent autonomy: `bot-autonomy.sh`

Every harness installed in the **bot** image runs non-interactively — no
per-action prompts, no interactive approval — because the container itself is
the isolation boundary. That policy is applied and re-verified by a single
entrypoint, `.devcontainer/scripts/bot-autonomy.sh apply|verify`, keyed by
`agent-registry.json`'s harness slugs, rather than by four independent scripts
that happened to be called from `post-create.sh` — the shape that let a real
regression (Codex silently staying at its human-profile sandbox) ship
unnoticed (harmon-init#1137). Bot `post-create.sh` runs `apply` after the
shared setup and the Antigravity compatibility installer; bot `post-start.sh`
runs `verify` again on every start, **before** the shared
`post-start-common.sh` script's Agent-Deck conductor-start block — a drifted
policy blocks the conductor from starting rather than letting it run for the
rest of its lifetime against a bad config. `apply` failing makes
`postCreateCommand` fail visibly; `verify` failing makes post-start fail; a
misconfigured bot image also fails the `devcontainer-build.yml` CI job, which
runs `verify` against the built container.

Every one of `agent-registry.json`'s registered harness slugs resolves to
exactly one of three buckets, checked by a unit test
(`task test:bot-autonomy`, part of `task verify` unconditionally — no
`.devcontainer/**` path filter, since a registry change is the failure mode
this exists to catch):

- **A module** — `.devcontainer/config/bot-autonomy/<slug>.sh` — for a harness
  actually installed in the image today: `claude-code`, `codex-cli`,
  `antigravity`, `opencode`, `copilot-cli`, `pi`, `oh-my-pi`.
- **An alias** to another slug's module, for a slug that launches the same
  executable under a different provider configuration: the six
  `claude-code-*` provider-rewired variants (DeepSeek, GLM, Kimi, MiniMax,
  Qwen, Qwen-local) all alias to `claude-code`.
- **An `unsupported` entry**, naming a reason and the executable `verify`
  checks for on `PATH` (or `null` for a slug with no installable binary at
  all, like the `claude-code-action` GitHub Action). The reason is
  documentation only — the instant a named executable turns up installed,
  `verify` fails naming it, exactly like an uncovered slug, regardless of why
  it was unsupported.

Per-harness boundaries: **Claude Code** sets `permissions.defaultMode` to
`bypassPermissions` in the managed settings (this also covers every
`claude-code-*` alias). **Codex** installs a complete, checksum-verified
`config/codex-managed-config.bot.toml` over the managed config, kept
structurally in sync with the shared human/bot baseline
(`config/codex-managed-config.toml`) by a parity test that fails if the two
files diverge on any key other than `sandbox_mode`/`approval_policy`.
**OpenCode** forces `permission.* = "allow"` in
`~/.config/opencode/opencode.json` on every `apply`, verified against
OpenCode's own *resolved* config (`opencode debug config`, run from the
workspace) rather than the global file alone, since a workspace-level
`opencode.json` can override the global default. **Antigravity** and **Copilot CLI**
are described below — they are the two harnesses whose autonomy is
Copier-gated, and their modules are still always present; only their policy
is conditional. **Copilot CLI** is
Copier-gated like Antigravity and described below. **pi** is the one module
whose `apply` deliberately writes *nothing*: pi's only prompt-avoidance knob
is project trust, and pi's own docs state that its non-interactive modes
(`-p`, `--mode json`, `--mode rpc`) never show a trust prompt at all — so the
bot already reaches the no-prompt state with pi exactly as it ships. What
trust would additionally buy is loading a repository's own `.pi/` resources,
which per pi's docs also means installing project packages and *executing
project extensions*; pi keys those decisions by canonical directory path with
no content or commit authentication, so both a global `defaultProjectTrust:
"always"` and a workspace-scoped `~/.pi/agent/trust.json` entry were reviewed
and rejected as unsafe defaults (the first trusts every repository this
installation is ever pointed at; the second survives an untrusted branch
checked out into the same path and extends to anything nested underneath it).
The bot therefore matches the dev profile exactly, accepting that headless pi
sessions silently skip project `.pi/` resources — and `verify` still fails
closed on *either* surface, whatever wrote it, including a trusted decision
that does not apply to the current workspace (the `~/.pi` volume outlives the
check, so an inapplicable decision becomes applicable the moment pi is pointed
at a matching path). **oh-my-pi** sets `tools.approvalMode: yolo` in
`~/.omp/agent/config.yml`, written explicitly rather than left to oh-my-pi's
own schema default, and verified against its *resolved* value (`omp config
get tools.approvalMode --json`, run from the workspace) because a
project-level `<cwd>/.omp/config.yml` overrides the global file the same way
OpenCode's workspace config does. Antigravity's,
OpenCode's and oh-my-pi's settings live on named volumes that outlive a container rebuild,
so each records the pre-`apply` value and offers a `restore` mode, the same
reversibility pattern.

**Antigravity autonomy is enabled.** Two profiles, two policies:

- **Bot profile — full autonomy.** It applies `always-proceed`, always accepts
  artifact reviews, allows non-workspace access, disables Antigravity's inner
  terminal sandbox, configures the devcontainer status line renderer, and trusts
  the current container workspace — the container is the isolation boundary.
  Interactive `agy` honors that policy directly; **headless `agy -p …` ignores
  settings allow-rules and auto-denies**, so bot `apply` installs a real
  executable at `~/.local/bin/agy` (`bot-autonomy/antigravity.sh`, replacing an
  earlier shell-function wrapper that only covered a login shell) that injects
  `--dangerously-skip-permissions` for agent runs. The `Dockerfile`'s
  `ENV PATH` puts `~/.local/bin` ahead of the system binary container-wide,
  so the wrapper's precedence holds for a `docker exec` or any other
  programmatic launcher too — not only interactive shells (a
  `devcontainer.json` `containerEnv.PATH` self-reference cannot work here:
  Docker passes `${containerEnv:PATH}` through unresolved when creating the
  container). A launcher that resolves `agy` some other way must still pass
  that flag itself.
- **Dev (human) profile — balanced.** It auto-accepts edits/artifacts and an
  allowlist of common commands (`task`, `git`, `gh`, linters, test runners, …)
  so routine work is prompt-free, but still asks before anything unlisted and
  keeps Antigravity's workspace and sandbox boundaries. Tune the allowlist in
  `.devcontainer/config/antigravity-settings-dev.json`.

Run `agy` interactively once to complete Google sign-in — Antigravity has no
API-key environment variable, so even a disposable container needs that one
human login; the pinned CLI falls back to file-backed credentials when the
headless container has no D-Bus keyring, and the `~/.gemini` named volume
persists the login across rebuilds. A checksum-verified compatibility installer
(`config/ensure-antigravity-cli.sh`) covers the interval before the shared-image
pin advances: `agy` is repointed to `~/.local/bin/agy-real` as a plain
symlink whenever an executable local copy exists — already at the
pinned version, or replaced from a matching system binary when it
wasn't. Once the image ships the pinned version directly, with no local
copy needed, it becomes a network-free no-op, leaving both files absent
on a fresh volume so `agy` resolves straight to the system binary; if
something already occupies `agy` at that exact point instead, it is left
exactly as found unless it would break a later replacement — a dangling
symlink (its target already gone) or a symlink to an existing directory
(which the bot's later wrapper install — an unguarded `mv -f` — cannot
cleanly replace, landing inside the directory instead) — either of which
this installer removes instead, in both profiles. Either way, the
bot's `apply` still installs its flag-injecting wrapper
over whatever this installer
leaves. It is gated on the rendered
`containerEnv.HARMON_BOT_AUTONOMY_ANTIGRAVITY` marker — turning the Copier
answer off downloads nothing and removes only a launcher or executable whose
own durable identity-and-content proof still matches; independent user files
and symlinks at either name are preserved. The settings helper backs up the
six policy keys it owns and tracks its
workspace-trust entry, so turning the Copier option off restores them while
preserving unrelated settings.

**Copilot CLI autonomy is off by default.** The CLI is available in the shared
image, but this template neither authenticates it nor weakens its permission
policy unless `use_copilot_cli` is explicitly enabled — its bot-autonomy
module still exists (a prompt-enabled Copilot CLI is the verified-correct
state at this answer, not an uncovered gap), it just installs no wrapper.
`COPILOT_ALLOW_ALL` is still rendered into the bot `containerEnv`, as the
explicit literal `"false"`: the bot profile also loads `devcontainer.env` via
`--env-file` and `init-env.sh` does not manage that variable, so an omitted
key — rather than an explicit one — would let a stale out-of-band
`COPILOT_ALLOW_ALL=true` in that file survive undisturbed. The dev profile
receives neither that variable nor the marker in either state. If an earlier
template update enabled the option, post-create removes the wrapper it
installed.

## Agent posture: the unattended profile

The **agent** posture (`.devcontainer/agent/`) is for an agent that runs
unattended somewhere nobody watches — a cloud VM, or work on untrusted input.
Untrusted input enters it as **data** (issues, diffs, pull request content);
the devcontainer definition itself must come from a trusted checkout — the
default branch or a reviewed ref — because `initializeCommand` runs the
checkout's code on the host, for this profile as for every other.
It is **never looser than bot on any axis**; the reasoning for every choice
is in harmon-init's three-posture ADR
([docs/decisions/2026-09-29-agent-posture-three-posture-model.md](https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-09-29-agent-posture-three-posture-model.md)).
Its containerEnv marker is `FOREMAN_DEVCONTAINER=agent`: scripts tell `bot`,
`agent`, and unset (dev) apart, and nothing reads `agent` as `bot`. Foreman
refuses to dispatch from it by design.

| Axis | What the agent devcontainer does |
|---|---|
| Identity | `AGENT_GH_TOKEN`, the agent's own fine-grained PAT on the bot account ([bot-account.md](bot-account.md)). post-create logs `gh` in from it; `GH_TOKEN` and its aliases are blanked. |
| Harnesses | Claude Code, through its managed allow/deny rules (auto mode, bypass disabled, no `ask`), and Codex, through its sandbox (`workspace-write`, never `danger-full-access`, approval `never`) with no command-level deny list. Every other installed harness is **refused**: `agent-autonomy.sh apply` makes its executable non-executable and `verify` fails if one is runnable again. |
| Secrets | Only `AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, and (opt-in) the alternative-provider keys. No 1Password, no Tailscale, never `ANTHROPIC_API_KEY`. |
| Network | Default-deny egress allowlist, enforced at every start from a root-owned snapshot taken at create. |
| Docker | None by default (see the opt-in below). |

The single source of its harness policy is `.devcontainer/config/agent/`
(`claude-managed-settings.json`, `codex-managed-config.toml`,
`harnesses.json`). Nothing else may carry a copy — `task test:agent-profile`
fails if one appears. `agent-autonomy.sh` installs it over the image's managed
settings at create and re-verifies it at every start.

### Where the agent's boundaries are

One first layer and two boundaries — only the boundaries are claimed as such:

- **Command-level denies are a best-effort first layer** for a cooperating
  harness. Claude Code's deny rules match the command it is about to run;
  Codex has no command-level deny list at all, only its sandbox. The denies
  are not transitive through repository code: the agent may run `task` and
  make commits, so Taskfile targets and git hooks run outside them. Pattern
  matching can also miss another spelling of the same flags, such as bundled
  short flags. Argument-pattern denies are defence in depth, not the write
  boundary. Raw `gh api` is explicitly denied; REST reads go through
  `/usr/local/bin/gh-api-read`, installed from `.devcontainer/config/agent/`
  independently of skills sync. It accepts one REST endpoint and a small
  allowlist of output flags, refuses methods, fields, bodies, headers,
  bundled flags, unknown flags and GraphQL, then pins `gh api --method GET`.
- **GitHub writes are bounded by the bot's collaborator grants, the agent
  PAT's scopes and the repository branch rulesets.** The PAT has no administration, secrets, or workflow permission;
  the rulesets refuse a direct or force push to `main`, and a merge to `main`
  needs code-owner approval and green required checks. They do not stop the
  PAT from merging: once a human has approved and the checks pass, its
  `pull_requests: write` can perform that merge. Its `contents: write` does
  let it create releases and push to any branch no ruleset protects — a
  fine-grained PAT cannot separate releases from contents.
- **The network is bounded by the egress filter** (below). Its residual is
  root: the container user keeps passwordless `sudo`, so repository code run
  with root can lift the filter; harmon-init#1432 tracks narrowing it.

The ADR's Consequences state the same in full.

### Agent env-file: fail closed

The agent's `initializeCommand` runs `init-env.sh --profile agent`. In that
mode the env-file may hold **only** the names the command allow-lists, and
the allow-list may name only `AGENT_GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, and
the alternative-provider keys. Any other name — the bot's `GH_TOKEN` or
`FOREMAN_AGENT_GH_TOKEN`, `TS_AUTHKEY`, an `OP_*` token, `ANTHROPIC_API_KEY`,
or a bare `NAME` line that would pass a host value through — **stops the
build** with the offending name (never its value). The other profiles quietly
evict a disallowed name; the agent profile refuses instead, because nobody is
watching to notice a repaired misconfiguration. The Codex login, where an
environment persists one (harmon-init#1406), lives in the `~/.codex` volume, not the
env-file.
The maintainer runs `codex login` once on the environment when provisioning it
(an agent never does: AGENTS.md § Hard Rules). Its
`~/.codex/auth.json` is never copied to another machine (the refresh token is
single-use, so a copy would invalidate both holders).

### Egress allowlist

The egress filter is installed first in both agent lifecycle scripts. It
reads `.devcontainer/egress-allowlist.txt` (the shared list, harmon-init#286)
plus the optional per-repo `.devcontainer/egress-allowlist.local.txt`, then
installs a default-deny netfilter policy: loopback, replies, DNS to the
configured resolvers, and the listed destinations pass; everything else is
refused. It needs `--cap-add=NET_ADMIN`, and it fails the container create
or start if the filter cannot be installed. Claude Code's deny rules cover `sudo`,
`iptables`, `nft`, and `ipset`, so it cannot lift the filter through its own
tools — the first layer above, not a boundary against repository code run
with root.

- **Applied from a root-owned snapshot.** post-create runs
  `egress-allowlist.sh establish`, which copies the applier and both lists out
  of the checkout into `/usr/local/share/harmon-egress/` (root-owned, closed
  to writes), and applies from there; every start applies that snapshot and
  never the checkout. An edit to the checkout's lists — by an agent or anyone
  else — changes nothing until the operator re-snapshots it.
- **Fails closed — and where it cannot.** Every step meant to install the
  filter (`apply`, post-create's `establish`, and post-start's apply of the
  snapshot), when it does not complete — a failed iptables install, a list
  the snapshot or the plan refuses, a failed rule or verify, a signal, or a
  missing snapshot — flushes the filter chain's allow rules, so a previous
  allowlist does not outlive a failed re-apply, and sets the OUTPUT and
  FORWARD policies to DROP, for every address family the container has
  (IPv4 always, IPv6 when it has a global address). It says egress was left
  at DROP only when every one of those steps succeeded; when one did not —
  iptables failing to install at all, or a DROP or flush step failing — it
  prints a `CRITICAL: could not close egress` line instead. Either way the
  create or start fails, and a container whose create or start failed must
  not be used: rebuild it after fixing the cause.
- **No over-broad entries.** A list line that is `0.0.0.0` in any form, or a
  CIDR wider than `/16`, fails `apply` closed with the file and line named.
  A range fetched through `@github-meta` is held to the same rule and fails
  `apply` closed naming `@github-meta` and the range. IPv6 literals are not
  accepted; IPv6 egress is closed outright.

- **A refused host leaves evidence.** `bash .devcontainer/scripts/egress-allowlist.sh blocked`
  prints every destination refused since the container started (address, and
  reverse name where one resolves), with no root needed. Put its output in the
  lane report of any unattended run that failed on the network.
- **Adding a host:** a need every repository shares goes in the shared list,
  with the reason; a need of this repository alone goes in
  `egress-allowlist.local.txt`. Either way, a rebuild picks it up, or, in a
  running container, `sudo bash .devcontainer/scripts/egress-allowlist.sh snapshot`
  followed by a restart.
- **Addresses are resolved at start.** A CDN that rotates addresses during a
  long run can start refusing a listed host;
  `sudo bash /usr/local/share/harmon-egress/scripts/egress-allowlist.sh apply`
  re-resolves.
- **The default bridge network only.** On a user-defined Docker network or a
  compose setup, `resolv.conf` points at Docker's embedded resolver
  (`127.0.0.11`), whose upstream queries are not in the allow set, so DNS
  resolution fails once the filter installs.

### Docker in the agent posture: per-repo opt-in

The agent devcontainer has **no Docker**: no Docker-in-Docker feature, and
never the host Docker socket (a socket mount hands the agent the host).
A repository whose gate needs Docker (harmon-infra) opts in with a
deliberate, reviewed edit to its `.devcontainer/agent/devcontainer.json` —
both halves, in the same change:

```jsonc
"features": {
  "ghcr.io/devcontainers/features/docker-in-docker:2": {
    "dockerDashComposeVersion": "v2"
  }
},
"containerEnv": {
  "HARMON_AGENT_DOCKER": "dind"
}
```

`HARMON_AGENT_DOCKER=dind` is the disclosure: `task test:agent-profile` and
`devcontainer-assert.sh` fail on Docker-in-Docker without it, and on a Docker
socket mount always. The nested daemon's containers are filtered by the same
egress allowlist (the filter hooks Docker's `DOCKER-USER` chain). Say so in
the PR that turns it on — it widens what the agent can build and run.

Two consequences of that hook come with the opt-in:

- **Nested containers cannot reach each other until you allow their
  subnet.** Traffic between two nested containers is forwarded too, so it
  also goes through `DOCKER-USER` → `HARMON_EGRESS`, and is rejected there
  like any unlisted destination. A repository whose nested containers talk
  to each other (a compose stack) adds its nested bridge subnet to
  `.devcontainer/egress-allowlist.local.txt` — for Docker's default bridge
  that is `172.17.0.0/16`, exactly at the list's `/16` floor.
- **An allowed destination skips Docker's own isolation chains.** An
  `ACCEPT` reached through `DOCKER-USER` ends the whole `FORWARD`
  traversal, so traffic to an allowlisted destination never reaches
  Docker's `DOCKER-ISOLATION-*` chains, which would otherwise keep separate
  nested networks apart.

## Run it locally

- **VS Code:** "Dev Containers: Reopen in Container" → pick the **Dev** profile
  (`.devcontainer/dev/`) for human use.
- **CLI:** `devcontainer up --workspace-folder . --config .devcontainer/dev/devcontainer.json`

Prebuilt images are pulled from GHCR as a build cache
(`ghcr.io/evanharmon1/harmon-devkit-devcontainer` / `ghcr.io/evanharmon1/harmon-devkit-devcontainer-dev`), so a warm rebuild
is fast. A cache miss is non-fatal — it just rebuilds from the `Dockerfile`.

## Bind-mounted checkout permissions

`post-create-common.sh` reconciles the bind-mounted workspace's `.git`
metadata tree on every attach: it reclaims ownership for the container
user (keeping the tree's original group), grants that group read/write,
sets directories setgid so new Git objects and refs stay group-writable
too (`core.sharedRepository`), and never leaves the tree world-writable.

**What this guarantees, and what it does not.** Write access after
reconciliation is guaranteed for the container user and for anyone
sharing the checkout's original group — in practice, same-uid re-attaches
(a container rebuild reusing the same runtime user) and other containers
or processes running as a group-mate. It does **not** extend trust to a
genuinely different host identity: Git's own "detected dubious ownership"
safety check is keyed on the file owner's uid, not on permission bits, so
a host process running as a *different* uid than the container sees the
reconciled checkout as owned by someone else regardless of the group
permissions — the same check that made `a+rwX` (world-writable) tempting
in the first place, and the reason this reconciliation never reintroduces
it. It is also a deliberate non-goal for a workspace root that is itself a
Git submodule or a `--separate-git-dir` checkout, rather than a linked
worktree: Git gives that shape no reverse pointer to validate a redirect
against, so the privileged mutation is skipped there (with a logged reason)
instead of trusting it, and the workspace still becomes usable without the
ownership repair. The reconciliation can only write its `safe.directory` trust entry
into the container's own environment-scoped Git config
(`.devcontainer/scripts/post-create-common.sh`'s `$ENV_GITCONFIG`), a
location a separate host machine's own Git installation has no way to
read.

**If a different-uid host needs to run Git directly against the same
checkout** (outside any container — for example a host-side terminal or
Git client, not a devcontainer attach), it needs its own one-time trust
entry:

```sh
git config --global --add safe.directory /path/to/the/checkout
```

Run that once, as the host user, against the exact path the checkout is
mounted at. It only grants that one path, never a wildcard, and it is
independent of the container's own reconciliation — repeat it if the
checkout is ever re-cloned to a new path.

## Claude Code settings in the container

Everything is sourced from `.devcontainer/config/` and baked into the **image**,
so a volume wipe can never leave the container without its policy, hooks, or
status line:

| What | Lives at | Source | Overridable |
|---|---|---|---|
| Managed settings | `/etc/claude-code/managed-settings.json` (image) | `config/claude-settings.json` | no (policy) |
| Managed drop-in: `gh pr merge` ask (**dev profile only**) | `/etc/claude-code/managed-settings.d/dev-gh-pr-merge-ask.json` (dev post-create) | `config/claude-settings-dev.json` | no (policy) |
| Hook scripts (mandatory) | `/etc/claude-code/hooks/` (image) | `config/claude-hooks/` | no |
| Hook scripts (optional) | `/usr/local/share/devcontainer-config/claude-hooks/` (**staged**) | `config/claude-hooks/` | no |
| Status line | `/etc/claude-code/statusline.sh` (image) | `config/claude-statusline.sh` | yes |
| User defaults | `~/.claude/settings.json` (**volume**) | `config/claude-user-defaults.json` | yes |

Two rows for hooks, because they are not installed the same way. A **mandatory**
hook is listed in the image installer's `required_files`, so every image is
guaranteed to place it under `/etc/claude-code/hooks/`. **Optional** hooks —
currently `session-end-archive.sh` — are installed
only when the repository ships them, so a settings entry naming the `/etc` copy
would break the moment the image pin were rolled back past the release that
added one. Those are registered at their **staged** path instead, where the
repository's own `COPY .devcontainer/config/` puts them regardless of which
image is pinned.

The practical consequence when troubleshooting: for an optional hook, the copy
under `/etc/claude-code/hooks/` is **not** the one that runs. Inspect or replace
the staged copy, and check `managed-settings.json` for the path actually
registered rather than assuming it.

### Managed PreToolUse hooks (`protect-files.sh`)

The container registers mandatory PreToolUse hooks under `/etc/claude-code/hooks/`.
Among them, `protect-files.sh` intercepts file edits (`Edit|Write|MultiEdit` in Claude Code,
and via `/etc/codex/hooks/file-payload.sh` in Codex) to safeguard sensitive credentials and configuration:

- **Protected set (credential-shaped paths only):**
  - Substring patterns: `.claude/settings.json`, `.codex/config.toml`, `/etc/claude-code/`, `/etc/codex/`
  - Suffix/glob patterns: `*.pem`, `*.key`, and the `.env` family where the basename starts with `.env` (such as `.env`, `.env.local`, `.envrc`) or ends with `.env` (such as `prod.env`).
- **Permitted paths:** Repository files and workflow state — including `.git/` (such as dev-flow v2
  run records in `.git/dev-flow-v2/` and deferred findings in `.git/deferred-findings/`), package
  lockfiles (`package-lock.json`, `uv.lock`), build and dependency artifacts (`node_modules/`, `dist/`),
  IaC state (`.terraform/`, `.tfstate`), and media/PDF files — are intentionally not blocked by this hook.

The hook script lives at `.devcontainer/config/claude-hooks/protect-files.sh` in the repository.
Because `/etc/claude-code/hooks/protect-files.sh` is baked into the container image at build time,
changes to the hook source take effect inside a container on devcontainer rebuild.

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

It is built to be cheap: ordinary renders use `jq` and `date`, no `git`
subprocess — the branch is read from `.git/HEAD` directly, worktrees included.

Claude Code's `pr.*` fields are absent until it discovers the open PR. The
optional **STATUSLINE PR LOOKUP** Copier answer (off by default) lets the
renderer fill that gap with a read-only `gh pr view` lookup when it was enabled
at scaffold time. Results are cached by git directory and branch: positive
results live for 30 seconds and negative/failure results for 10.
On a cache miss or expiry, the current render can wait for one read-only,
`GH_PROMPT_DISABLED=1` lookup, hard-capped at one second; ordinary cached renders
stay local. Payload PR data always wins. Missing `gh`/`timeout`, failed GitHub
discovery, or absent repository access simply leave the segment empty; the
lookup cannot manufacture PR data.
Set `STATUSLINE_PR_LOOKUP_ENABLED=0` to disable an enabled fallback at runtime.

To use your own instead, point `statusLine.command` in `~/.claude/settings.json`
at it — the seed merge will not overwrite it or add `refreshInterval`.

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

Codex settings arrive as **two** layers, and the split is load-bearing.
Boundary policy is baked at `/etc/codex/managed_config.toml` from
`config/codex-managed-config.toml` — Codex's legacy MDM layer, where every key
is an unoverridable requirement that beats `-c`, `~/.codex/config.toml` and a
trusted project `.codex/config.toml` without saying so. Only the sandbox and
approval boundary and the image-owned hooks belong there. Overridable defaults
— model, reasoning effort, the project-instruction budget and the status line —
are baked at `/etc/codex/config.toml` from `config/codex-system-config.toml`,
so an agent or orchestration session can raise the effort for one run. Pinning
those in the managed layer silently downgraded dispatched workers instead.
Together they default to Sol/medium, load the standard project skills from
`.agents/skills`, and render a compact built-in footer with project, branch,
model/effort, context, quota, token, and run-state fields. Its shared hook
adapters are installed under `/etc/codex/hooks/`. Unlike
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

## OpenCode

The shared image installs the stable `opencode` CLI with no repository or user
configuration layered on top. Start it with `opencode`, then use `/connect` (or
`opencode auth login`) to choose and authenticate a provider. OpenCode continues
to read this repository's `AGENTS.md` as its project instructions.

Both its user config (`~/.config/opencode`) and application data
(`~/.local/share/opencode`, including authentication and conversations) use
profile-specific named volumes; Coder maps the same paths into
`~/.persistent`. Rebuilding the container therefore keeps future custom config,
provider logins, and sessions. The image disables OpenCode's self-updater so the
pinned, tested version remains stable until the shared image is rebuilt.

The **bot** profile forces `permission.* = "allow"` in `opencode.json`
(`bot-autonomy/opencode.sh`, part of the [bot-only agent
autonomy](#bot-only-agent-autonomy-bot-autonomysh) bootstrap above) so OpenCode
never prompts; the **dev** profile leaves OpenCode at its own out-of-the-box
defaults.

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

To attach from a laptop, either SSH in and run it there:

```bash
coder ssh <workspace>.devcontainer
herdr
```

or let Herdr do the SSH itself — this form runs a **local** Herdr thin client,
so install Herdr on the laptop first (`brew install herdr`, or the installer
at [herdr.dev](https://herdr.dev/)):

```bash
herdr --remote coder.<workspace>.devcontainer
```

`coder config-ssh` is what writes the `Host coder.*` ProxyCommand aliases into
your SSH config, so run it once before the `--remote` form. Both forms target
the Coder `devcontainer` agent; the topology, transport, security rationale,
and rebuild caveats are in [Bot-profile access from Coder](#bot-profile-access-from-coder).

`~/.config/herdr` is a **named volume** (`herdr-config-…`, one per profile; on
Coder it is symlinked into the `~/.persistent` volume instead), so Herdr's own
state survives a rebuild: snapshot restore brings the workspace shape back —
tabs, panes, cwds, layout — as fresh shells. Whether an agent *conversation*
resumes inside its restored pane is a separate mechanism:
`resume_agents_on_restore` only works for agents whose Herdr integration has
recorded a native session reference. post-create installs the Claude Code,
Codex, OpenCode, Copilot CLI, pi, and oh-my-pi integrations automatically
(`herdr integration install`, idempotent). The conversations themselves
persist regardless, in the `~/.claude`, `~/.codex`, `~/.local/share/opencode`,
`~/.copilot`, `~/.pi`, and `~/.omp` volumes (`~/.gemini` holds Antigravity's
own OAuth/session state, not a CLI conversation, so it's not one of these),
so a pane that restores as a plain shell can still resume its agent by hand
(e.g. `claude --resume`).

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
  --web --scopes "$(bash -c '. scripts/gh-scopes.sh && gh_scopes_request_list')"
gh auth setup-git
```

The scope list is **derived**, not typed: `scripts/gh-scopes.sh` is the single
source this repo's session-start check and `task setup:gh-scopes` read, so the
login above asks for exactly what the check demands — including profile-specific
additions such as `admin:org` in an organization repo. Outside a checkout, use
the literal `--scopes "workflow,project"` and then run `task setup:gh-scopes`
once you have cloned, which adds anything missing and verifies it landed.

The human profile sets `GH_BROWSER` to a small host-browser bridge. In a remote
VS Code session, it uses the server's `bin/helpers/browser.sh` handoff; with a
desktop CLI, it uses `code --open-url` only when that CLI advertises the option.
On Coder, the plain CLI, or a disconnected VS Code session where neither handoff
is available, the bridge prints the exact URL to open manually. It deliberately
never tries `w3m`, `lynx`, or generic browser discovery, so an installed terminal
browser cannot capture the flow. Both the initial `gh auth login --web` and the
browser flow used by `task setup:gh-scopes` inherit this behavior from
`GH_BROWSER`.

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

Nothing fails hard before you log in. `post-create` prints the commands above,
public sibling repos clone via HTTPS fallback while private ones are skipped
with a warning (missing siblings are automatically cloned in the background on
container start and upon completing `task setup:gh-scopes`). What does
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
(Moonshot Kimi K3, DeepSeek V4.1 Flash, Z.AI GLM-5.3, Alibaba DashScope Qwen3.8-Max /
Qwen3-Coder-Plus — no proxy), plus the per-tier `ANTHROPIC_*_MODEL` vars
(`claude-qwen` uses Qwen3.8-Max for the main/reasoning roles,
Qwen3-Coder-Plus for coding, and Qwen3.8-Flash for lightweight/subagent roles). The functions live in
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

**This warning is not itself a failure.** `initializeCommand` runs on the host,
where a non-zero exit aborts the whole build, so a missing optional secret must
not block a rebuild there — it is a signal to read.

What happens next depends on the secret. For most, the container comes up clean
and only the dependent step fails later, far from the cause.
That includes `TS_AUTHKEY`. The dev profile installs Tailscale and still
connects whenever a key is present — a missing one is a skip, not a failure, so
the container comes up either way. Answer `tailscale_required` at scaffold time
to make it fatal instead: worth it for a profile whose whole point is the
tailnet, where a container that starts up logged out is easy to miss for hours.

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
     (+ `TS_AUTHKEY` if you want Tailscale — without it the dev profile
     simply skips the tailnet connect); `KIMI_API_KEY`/`MOONSHOT_API_KEY`,
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

### Bot-profile access from Coder

The Coder `devcontainer` template exposes **two agents per workspace**:

- **`host`** — the outer workspace container, running as `coder`, with Docker
  and the repo checkout at `~/<repo>`, but no toolchain.
- **`devcontainer`** — the inner devcontainer, running as `vscode`, with the
  repo at `/workspaces/<repo>`, all tools, and Herdr.

These two profiles both name their inner Coder agent `devcontainer`; the
`.devcontainer` suffix selects the inner agent, not the security profile. These
commands assume the workspace was created from the **Bot** profile
(`.devcontainer/devcontainer.json`), not the human **Dev** profile
(`.devcontainer/dev/devcontainer.json`). Verify the selected config before
allowing a bot to run; if it is the Dev profile, use the human workflow and do
not treat this target as a bot boundary. `coder ssh <workspace>` fails with
`multiple agents found, please specify the agent name, available agents:
[devcontainer host]`. The working forms are:

```bash
coder ssh <workspace>.devcontainer

# After `coder config-ssh` has written the Host coder.* ProxyCommand alias:
ssh coder.<workspace>.devcontainer

# Herdr wraps that SSH transport as a local thin client:
herdr --remote coder.<workspace>.devcontainer
```

In a Coder-hosted bot workspace, the devcontainer has no `sshd`, no
`tailscale`/`tailscaled`, and no inbound listener. The Coder remote-access
process is `/.coder-agent/coder agent`, which holds an **outbound** connection
to the Coder server. Every SSH session is carried down that tunnel: the local
`coder ssh --stdio` ProxyCommand authenticates to the Coder control plane with
the operator's CLI session, and the agent terminates the SSH protocol
in-process. Other ordinary processes may make outbound network requests, but
they do not create an inbound SSH or tailnet path. Access is gated by Coder
login and RBAC and appears in Coder's audit log. Coder's transport embeds its
own WireGuard/DERP mesh internally; that is inside the `coder` binaries and is
unrelated to the operator's Tailscale tailnet.

This is the deliberate access model for an AI-agent container because the bot
is the **untrusted** party: Claude runs `bypassPermissions`, Codex runs
`danger-full-access`, and the container holds the bot PAT plus whatever the
env-file carries. Adding Tailscale would not "open a port" — Tailscale is also
outbound-only WireGuard, and Tailscale SSH is deny-by-default until an ACL
grants it. The risk is the other direction: the container would gain a tailnet
identity and outbound reach to every node that ACL allows, a second credential
class (`TS_AUTHKEY`) would live beside the agent, and a second access path
would exist outside Coder's RBAC and audit trail. That is why the bot profile
strips `TS_AUTHKEY` and omits the Tailscale feature. The tailnet is reserved for
the **dev/operator** profile: humans using their own identity, including the
case that needs Coder-independent access such as a phone SSH client that
cannot run the `coder` CLI.

The trade-off is explicit: the Coder control plane is the **single trust
root**. It is an internet-exposed web app, and a compromised Coder session or
server yields a shell in every workspace. Put the controls there: SSO/MFA on
the Coder account, short session lifetimes, and timely patching of the Coder
server and agents.

#### Herdr over Coder

`herdr --remote` needs only working OpenSSH, so it works against the bot
container exactly as it does against a dev container — the ProxyCommand is the
transport; no Tailscale is needed. Herdr stays a thin client on the laptop,
providing local keybindings and clipboard/image-paste bridging, while the
server and agents run in the container. Detach with `ctrl+b q` and reattach
with the same `herdr --remote coder.<workspace>.devcontainer` command.

`herdr --remote` prefers a remote binary matching the local client version.
The image pins `HERDR_VERSION` (0.8.2 today), while a laptop may already have
a newer patch release installed. On a mismatch, an interactive run prompts to
install a matching binary into `~/.local/bin` on the remote. That directory is
first on the container `PATH` but is **not** a persisted volume, so the prompt
recurs after every container rebuild until the image's `HERDR_VERSION` catches
up; Renovate tracks that pin.

#### Rebuild before attaching to a changed image

A Coder workspace **restart** reuses the cached `vsc-<repo>-<hash>` devcontainer
image. A repo bump to `.devcontainer/Dockerfile`'s base therefore does not
reach a running workspace until the devcontainer is explicitly **rebuilt**.
The symptom is `herdr` missing and `HERDR_SOCKET_PATH` unset inside the
container, even though the pinned base image ships both. Do not work around it
by letting `--remote` install into `~/.local/bin` on a pre-Herdr image: with
`HERDR_SOCKET_PATH` unset, the socket lands in the volume-persisted
`~/.config/herdr`, which is exactly the stale-socket hazard described above.
Rebuild first, then attach.

## Attach paths and container managers

**Two different managers can attach VS Code to the same dev container**, and
they are not interchangeable:

| Manager | How you start it | `REMOTE_CONTAINERS` | `devcontainer.json` `customizations.vscode` |
|---|---|---|---|
| **Dev Containers extension** | "Dev Containers: Reopen in Container" | `true` | applied |
| **Coder devcontainer integration** | the Coder UI **VS Code** button, or a Coder-direct connection to the `devcontainer` agent | unset | **not** applied |

That second row is the one that surprises people. A Coder-attached window is a
perfectly good shell in the right container, but nothing in
`customizations.vscode` reached it — settings, and the extension list, are
whatever your Coder-side configuration provides. `post-create-common.sh` already
branches on `REMOTE_CONTAINERS` for the git-credential handling, so the two
paths differ in mechanism even where they agree on identity.

For a direct bot shell or Herdr session, use the `devcontainer` agent and the
explicit target forms in [Bot-profile access from Coder](#bot-profile-access-from-coder).

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

Coder is still how you reach the workspace **host** — the outer agent described
in [Bot-profile access from Coder](#bot-profile-access-from-coder). The split
below is only about which layer makes the *container* hop. The extension path,
concretely:

1. **Connect to the workspace itself** (Coder UI button or "Coder: Open
   Workspace"). If the picker offers both the workspace and a
   `devcontainer` sub-agent target, choose the **workspace** (the host agent)
   for this nested extension path — the sub-agent target is the Coder-direct
   hop described above.
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

   The README's **Coder Dev Container** badge is the same recommendation in a
   clickable surface. Its target must be captured from VS Code rather than
   reconstructed: run `~/bin/open-devcontainer` with no arguments, choose the
   matching `[token]`, then print the exact launch without opening it:

   ```sh
   OPEN_DEVCONTAINER_DRY_RUN=1 ~/bin/open-devcontainer <token>
   ```

   Copy the `vscode-remote://dev-container+…` value after `--folder-uri` into
   the template's `devcontainer_coder_folder_uri` answer. The README converts
   that internal folder URI to VS Code's registered
   `vscode://vscode-remote/…` protocol form before routing it through
   `vscode.dev/redirect`. Before publishing the README, first round-trip the
   captured value with `code --folder-uri '<captured-uri>'`, then click the
   rendered badge from the README; only keep it if both paths open this repo's
   dev profile through the currently installed Dev Containers extension. The
   hex payload is an extension implementation detail, so repeat this capture
   and validation whenever an extension update invalidates the link. Leaving
   the answer empty omits the personal Coder badge and retains the clearly
   labeled **Local Dev Container** clone-in-volume fallback.
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

Nothing here is data loss by design: agent state, shell history, and zoxide
data all sit on named volumes precisely so a recreation is survivable, and
`~/.claude.json` is symlinked onto one for the same reason (below). What is
lost is container-local scratch — and, in `dev/`, the `gh` login, which is on
no volume by decision rather than by omission (see
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
  and in the background on container **start** (`.devcontainer/scripts/bootstrap-related-repos.sh`),
  with fallback to `git clone` for public repos when `gh` is unauthenticated,
  and re-triggered upon completing `task setup:gh-scopes` — so a rebuilt or
  persistence-lost container re-populates them and missing siblings clone
  automatically once authenticated;
- **fetched** non-destructively on container **start**
  (`.devcontainer/scripts/fetch-related-repos.sh`).

Both are safe to re-run: an already-cloned sibling is **never clobbered** —
clone skips it, and start runs `git fetch` only (never pull / merge / checkout),
so uncommitted work, local commits, and the checked-out branch stay put.
Overlapping runs are safe: each repo is cloned into its own private temporary
directory and moved into place atomically on success, so only one run can
publish and a failed or interrupted clone never deletes a user's existing
checkout.
When a sibling does not appear after a start or a scope refresh, read the logs:
`$HOME/.related-repos-bootstrap.log` holds the clone job (from container start
and from `task setup:gh-scopes`) and `$HOME/.related-repos-fetch.log` the fetch job.
The list is preserved across `copier update` (an empty list is a no-op).

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
