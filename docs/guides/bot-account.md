# The bot account and its PAT

How the `evanharmon1-bot` machine account gets access, and
how to mint the fine-grained PAT it authenticates with.

Read this when standing up a new bot account, adding the bot to a new repo, or
rotating the token. The *why* lives in
[architecture/security.md](../architecture/security.md); the permission table is
owned by
[architecture/branch-protection.md](../architecture/branch-protection.md#bot-account-pat-permissions);
this is the *procedure*.

## Why a separate account

Two identities, deliberately:

- **`evanharmon1-bot`** — the AI agent's identity inside
  the bot devcontainer. Write access, no admin; it cannot push to `main`, and
  nothing merges into `main` without the operator's code-owner approval.
- **`evanharmon1`** (you) — the operator. Full access,
  from the human `dev/` profile or the host.

The split is what makes "nothing reaches `main` without the operator's
approval" enforceable server-side rather than by convention. Anything running
in the bot devcontainer can read this token out of the environment, so treat it
as the agent's own credential and give it nothing you would not give the agent.

CI *workflows* are a **third** identity — they authenticate as the
`evanharmon1-ci` GitHub App with short-lived tokens, not this PAT. Don't
conflate them; see [architecture/security.md](../architecture/security.md).

## The two-layer access model

**Effective access = min(collaborator grant, PAT permissions).**

A fine-grained PAT is a *delegation of its owner's access* and can never exceed
it. Two layers must both allow an operation:

| Layer | Granularity | Sets |
|---|---|---|
| Repo collaborator grant on the bot | **per repo** (`pull` / `push` / …) | the ceiling |
| PAT selected-repo list + permissions | **uniform across all selected repos** | what the token may attempt |

There is no per-repo permission matrix inside a PAT. So **per-repo granularity
lives in the collaborator grant**, and one PAT can back a mix of read-only and
writable repos: a repo where the bot is a `pull` collaborator stays read-only
even though the token carries `contents: write`.

Two consequences worth internalising, because both cause confusing failures:

- **To narrow the bot on a repo, change the collaborator grant — not the PAT.**
- **Both layers, in order.** Adding a repo to the PAT's list does nothing if the
  bot has no access to it; granting access does nothing if the repo is not in the
  list. A "404" from `gh` usually means the first; a "Resource not accessible"
  usually means the second.

## One PAT per resource owner

A fine-grained PAT is scoped to a single **resource owner** — a user *or* an org,
never both. A token owned by `evanharmon1` cannot reach
`evanharmon1/…` repos, and vice versa.

So you need **one PAT per owner whose repos the bot works on**, each with its own
selected-repo list. This is the same containment logic as one CI App per org: a
leaked token reaches one owner's repos, not everything.

## Procedure

### 1. The bot account (once, ever)

A normal GitHub account named `evanharmon1-bot`. Give it
its own email (an alias is fine), enable 2FA, and store the credentials in
1Password. It does **not** need a paid seat for public repos or for
collaborator access to a personal account's private repos; an org may consume a
seat.

### 2. Repo access — the collaborator grant

This repo lives under the personal account `evanharmon1`,
so `task setup:github` does **not** add the bot — that step only runs for org
repos. Add it by hand if the bot needs access:

```bash
gh api repos/evanharmon1/<repo>/collaborators/evanharmon1-bot \
  --method PUT -f permission=push    # or `pull` for clone-only access
```

The bot must accept the invitation before the grant takes effect. Verify:

```bash
gh api repos/evanharmon1/<repo>/collaborators/evanharmon1-bot/permission \
  --jq '.permission'
```

### 3. The PAT (manual — there is no API for creating one)

Signed in **as the bot**: GitHub → Settings → Developer settings → Personal
access tokens → **Fine-grained tokens** → Generate new token.

| Field | Value | Why |
|---|---|---|
| **Resource owner** | the owner of the repos — `evanharmon1` | Pick the *user* and org repos are unreachable, no matter the permissions. An org may require approval before the token works. |
| **Repository access** | *Only select repositories* — exactly the repos the bot works on | This list **is** the blast radius. Never "All repositories". |
| **Repository permissions** | the table in [branch-protection.md](../architecture/branch-protection.md#bot-account-pat-permissions), and nothing more | Notably **no Workflows** and **no Administration** — see [security.md](../architecture/security.md). |
| **Expiration** | set one; record the date | A token that never expires is a credential you will never rotate. |

Copy the value once — GitHub will not show it again.

### 4. Store the value

Into **1Password**, then to the container via the 1Password Environment that
backs the devcontainer's `--env-file`, as `GH_TOKEN` — see
[devcontainers.md](devcontainers.md). Never into git, never into
`containerEnv`, never pasted into a shell that records history.

Into the **bot** profile's env-file only. The human `dev/` profile carries no
`GH_TOKEN` — it authenticates as the operator via `gh auth login`, and `gh`
would prefer this PAT over that login unconditionally if both were present.

### 5. Verify end to end

From inside the bot devcontainer:

```bash
gh auth status                       # should report the bot's login, via GH_TOKEN
gh api user --jq .login              # => evanharmon1-bot
git ls-remote https://github.com/evanharmon1/<repo> HEAD   # auth works for git, not just gh
```

That last one matters and is easy to miss: `gh` reads `GH_TOKEN` directly, but
**git does not**. Git works only because `post-create` runs `gh auth setup-git`
on the headless path, bridging the token into git's credential helper. If `gh`
works and `git` doesn't, that bridge is what to look at.

Then prove the boundary holds — a push to `main` must be **rejected**:

```bash
git push origin HEAD:main    # expected: rejected by the ruleset
```

If that succeeds, the ruleset is missing or misconfigured. Stop and fix it before
letting an agent loose; see
[architecture/branch-protection.md](../architecture/branch-protection.md).

## Adding the bot to another repo later

Both layers, in order:

1. Grant the collaborator access (step 2) — `push`, or `pull` if the bot only
   needs to read it.
2. Edit the PAT's **selected repositories** to include it.

Miss either and it fails in a way that looks like a permissions bug.

## Rotation

Fine-grained PATs expire. When the date arrives — or on any suspicion of leak —
generate a new token with the same settings, update the 1Password item, and
rebuild the devcontainer so the env-file re-reads it. Nothing else references the
value, which is the point of keeping it in exactly one place.

A leaked bot PAT is bounded but not harmless: it can push branches and open PRs
on the selected repos.
It **cannot** push to `main`, edit workflows, or change repo settings, and it
can merge into `main` only a PR a human has already approved with green
checks — merging stays the maintainer's decision. Revoke, re-issue, and check
the repos' branch and PR lists for anything you did not create.

## The agent PAT (the agent posture's own token)

The **agent** devcontainer (`.devcontainer/agent/`; see harmon-init's
[three-posture ADR](https://github.com/evanharmon1/harmon-init/blob/main/docs/decisions/2026-09-29-agent-posture-three-posture-model.md))
authenticates with a **separate** fine-grained PAT on the same bot account —
never the bot's own `GH_TOKEN`:

- **Same permissions as the bot's PAT** (the table above), so it can push
  feature branches, open draft PRs, comment, and label, and has no
  administration, secrets, or workflow permission. The rulesets refuse a
  direct or force push to `main` and require code-owner approval and green
  required checks for a merge into it; as with the bot's PAT, once a human
  has approved and the checks pass, its `pull_requests: write` can perform
  that merge, and merging stays the maintainer's decision. Its
  `contents: write` does let it create releases and push to any branch no
  ruleset protects, because a fine-grained PAT cannot separate those from
  contents.
- **Expiry of 180 days at most** — shorter than the bot's — and its **own
  selected-repository list**, limited to the repositories that allow remote
  lanes. One per resource owner, for the same reason as above.
- **Supplied as `AGENT_GH_TOKEN`** in the host environment. `init-env.sh
  --profile agent` projects it into `.devcontainer/agent/devcontainer.env`
  and refuses to build if that file holds any other credential; the agent
  post-create logs `gh` in from it. A distinct name is the point: a host
  that exports the bot's `GH_TOKEN` can never feed it to an agent container.

Revoke it independently of the bot's PAT: rotating one never touches the
other. For Claude Code on the web, where `/web-setup` holds a single token
across resource owners, the agent identity is instead a **classic** PAT on the bot
account with `repo` scope and no `workflow` scope, handed to `/web-setup` with
the account's Claude GitHub App connection removed. It is bounded by the bot's
per-repo collaborator grants rather than by a selected-repository list (a
classic token reaches every repository the bot can, across owners), and GitHub
refuses a push that changes `.github/workflows/` (observed 2026-10-07). The one
exception is the alternative of authorizing the Claude GitHub App as the bot,
under which a web session **can** push workflow files; see
[harmon-init's Claude Code on the web guide](https://github.com/evanharmon1/harmon-init/blob/main/docs/guides/claude-code-web.md#whose-identity-github-sees)
for the procedure, the account pitfall and the costs (harmon-init#1407).

That classic web PAT has its own lifecycle. Set an expiry (180 days at most, like
the agent PAT), keep it in the bot's item in your secret store, and rotate it by
minting a new token and re-running `/web-setup`. Retire it by revoking it on
GitHub (Settings → Developer settings → Tokens (classic)): whether disconnecting
GitHub on claude.ai's connectors page removes a stored token was not observed.
Per-session repository scope does not limit this agent: a session can attach,
when a human approves, any repository the bot can push to. A classic `repo`
token also carries `repo:status`, `repo_deployment` and `security_events` on
those repositories, and `repo:invite`, which lets it accept a pending
collaborator invitation to the bot (someone with admin access still has to
send it). GitHub documents that `repo` also reaches organization-owned
resources (projects, invitations, team memberships, webhooks) as far as the
bot's organization role allows.

## What the bot cannot do — by construction

- **Push to `main`, or merge into it unapproved** — the rulesets refuse a
  direct or force push to `main` for every actor, and require code-owner
  approval (the operator's, per CODEOWNERS) and green required checks for a
  merge. A PAT with `pull_requests: write` — this one or the agent's — can
  perform a merge a human has already approved; merging stays the
  maintainer's decision.
- **Edit `.github/workflows/`** through its PATs — no Workflows permission, so
  it cannot rewrite CI to run with Actions secrets. The App-as-bot route on
  Claude Code on the web is the exception (see
  [harmon-init's Claude Code on the web guide](https://github.com/evanharmon1/harmon-init/blob/main/docs/guides/claude-code-web.md#whose-identity-github-sees)).
- **Change settings, rulesets, or bypass lists** — no Administration.
- **Reach production secrets** — the bot devcontainer installs no 1Password CLI
  and no Tailscale.

No single layer is sufficient alone: the PAT limits what the token may *attempt*,
the ruleset limits what GitHub *allows*, and CODEOWNERS decides *whose approval
counts*.
