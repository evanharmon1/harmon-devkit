# Security, Permissions & Secret Strategy

How **Harmon DevKit** handles identity, permissions, and secrets. Keep this
current — it is the reference for "where do secrets live and who can do what".

> TODO: fill in the project-specific details below as the threat model firms up.

## Core principles

- **Least privilege.** Every token, account, and workflow gets the narrowest
  scope that still works.
- **Secrets via 1Password.** Local env comes from **1Password Environments**
  (a virtual `.env` mounted over a UNIX pipe — never written to disk or git) or
  `op run`/`op inject`; CI reads from GitHub Actions secrets.
  Devcontainer secrets are `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `AGENT_DECK_TELEGRAM_KEY` (+ `TS_AUTHKEY`, dev profile only) — see
  [../guides/devcontainers.md](../guides/devcontainers.md).
  TODO: list the 1Password vault/items this project uses.
- **Auditable changes.** `main` is protected; changes land via reviewed PRs
  (see [branch-protection.md](branch-protection.md)).

## Two identities: the bot vs the operator

- **AI bot** (`evanharmon1-bot`) — runs in the primary
  devcontainer with a scoped fine-grained PAT (Write, no admin) for its in-container
  git pushes. Cannot push to or merge `main`. (CI **workflows** authenticate
  separately as the `evanharmon1-ci` GitHub App — see below.)
- **Operator** (you) — full access from the human `dev/` devcontainer or host.

TODO: note the exact PAT scopes and any capabilities the bot is intentionally
denied (e.g. no Tailscale, no production credentials).

## CI automation identity (GitHub App)

CI workflows that act on the repo as a bot — release-please, the
`claude-*` workflows — authenticate as a
**GitHub App dedicated to this owner**, not a personal access token. **Each
GitHub org (and personal account) gets its own App**, named **`<owner>-ci`** —
for this repo, **`evanharmon1-ci`**. One App per org keeps a leaked key
contained to a single org (no cross-org reach).

Each job mints a short-lived (1h) installation token at runtime via
`actions/create-github-app-token`, reading:

- `CI_APP_CLIENT_ID` — Actions **variable** (this App's **Client ID** — the `Iv…`-style
  string from the App's settings page, NOT the numeric App ID; not secret)
- `CI_APP_PRIVATE_KEY` — Actions **secret** (this App's PEM private key)

Set both once as **org-level** Actions variable + secret (every repo in the org
inherits them); for a personal-account repo, set them per-repo.

### Creating the `evanharmon1-ci` App (once per org)

Create the App **by hand.** GitHub's app-manifest ("one-click") flow only
finalizes an app through a server-side callback it redirects to, so a static page
can't complete it (it redirects, the one-time `?code=` expires unused, and no app
is created) — there is no working shortcut. The exact permission set is checked in
as [`.github/github-app-manifest.json`](../../.github/github-app-manifest.json) as
a machine-readable reference; mirror it in the form.

1. Open **New GitHub App** — for an org,
   `https://github.com/organizations/evanharmon1/settings/apps/new`; for a
   personal account, `https://github.com/settings/apps/new`
   (**Settings → Developer settings → GitHub Apps → New GitHub App**).
2. Set **GitHub App name** `evanharmon1-ci` (names are globally unique — if
   it's taken, add a suffix; the workflows reference the **Client ID**, not the
   name), **Description** = the `description` from the manifest (optional,
   cosmetic — documents what the App is for), **Homepage URL** = the owner's page
   `https://github.com/evanharmon1` (also required-but-cosmetic — it doesn't
   scope the App to any repo; the App is owner-wide), **uncheck the "Active"
   webhook**, leave **"Expire user authorization tokens"** checked (the default —
   CI uses installation tokens, not the user-to-server tokens this governs), grant
   the permissions in the table below, and choose **"Only on this account"**. Then
   scroll down and click **Create GitHub App**.
3. **Generate a private key** (downloads a `.pem`) and copy the **Client ID**
   (shown at the top of the App's settings page — not the numeric App ID).
4. **Install App** → on this org, **Only select repositories** (not "All").
5. Set `CI_APP_CLIENT_ID` (Actions variable = the App's Client ID) and `CI_APP_PRIVATE_KEY`
   (Actions secret = the `.pem` contents) — org-level for an org, per-repo for a
   personal account. **Set the private key by piping the `.pem` file in, never by
   pasting it** — redirecting the file preserves its newlines, whereas a copy-paste
   into the web UI (or a `gh secret set -b "…"` string) can flatten them and leave
   the key undecodable. `create-github-app-token` then fails at JWT-signing time
   with `error:1E08010C:DECODER routines::unsupported` (or `Invalid keyData`):

   ```bash
   # personal account / single repo:
   gh secret set CI_APP_PRIVATE_KEY --repo <owner>/<repo> < evanharmon1-ci.*.private-key.pem

   # org: set the value once, scoped to the repos that need it now (add the
   # variable the same way). Then finalize/audit repo access in the UI — see below.
   gh secret set CI_APP_PRIVATE_KEY --org evanharmon1 \
     --visibility selected --repos <repo>[,<repo2>] < evanharmon1-ci.*.private-key.pem
   ```

**Set the secrets by hand — don't script it.** Run the `gh variable set` /
`gh secret set` commands deliberately; **key rotation is manual too.**

**Recommended process — the CLI sets the value, the UI owns the repo list.** Set
the value once from the `.pem` file (above), scoped with `--visibility selected
--repos` to whatever repos make sense at the time (selecting them all is fine if
that's the reality). From then on, **finalize and maintain which repos can read
it in the GitHub UI** — org → *Settings → Secrets and variables → Actions* → the
secret → **Repository access**. Editing the list there changes scope **without**
re-entering the value, and the page doubles as a sanity check of exactly who has
access. Don't reach for `--visibility all` as a shortcut: it exposes the key to
every org repo until you narrow it.

Keep list-management in the UI because `gh secret set` is **declarative** — the
`--repos` form *replaces* the secret's value **and** its whole repo allow-list on
every run, so re-running it from a second repo silently evicts the first. The UI
(or `PUT /orgs/{org}/actions/secrets/{name}/repositories/{repo_id}`) is the
non-destructive way to add a repo.

**Why an App, not a PAT:** tokens are short-lived (nothing to rotate yearly), the
App consumes no user seat, permissions are granular, and — unlike the built-in
`GITHUB_TOKEN` — App-token-authored PRs/pushes DO trigger CI (so a release PR's
required checks actually run). Commits the App pushes are attributed to
`<app-slug>[bot]`.

**Required App permissions** — select each of these on the form (the form
pre-checks nothing, **Metadata included**, so set them all explicitly); grant
nothing more:

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | commits, branches, tags, releases |
| Pull requests | Read and write | open/update the release PR and claude PRs |
| Issues | Read and write | claude comments/labels/updates issues |
| Workflows | Read and write | claude may edit files under `.github/workflows/` |
| Metadata | Read-only | required baseline |

### Blast radius & key protection

Tokens minted at runtime are scoped to **one installation** and expire in ~1h.
Because **each org has its own App and key**, the App private key only ever
reaches **this** org — a key compromise cannot cross into another org. To keep
even the in-org radius small:

- **Install on selected repos**, not "All repositories", to bound what a key
  compromise can touch within the org.
- **Protect `CI_APP_PRIVATE_KEY`**: it lives only in Actions secrets. Never read
  it from workflows that untrusted code can influence (fork `pull_request`,
  `pull_request_target`, `workflow_run`) — the provided workflows gate on
  sender / same-repo checks.
- **Rotate the key** periodically; GitHub Apps allow multiple keys for
  zero-downtime rotation.

## Token & secret inventory

TODO: enumerate the tokens/secrets this repo depends on and where each lives:

| Secret / variable | Used by | Stored in | Rotation |
|---|---|---|---|
| `CI_APP_CLIENT_ID` (var) + `CI_APP_PRIVATE_KEY` (secret) | release-please, claude-* | repo or org Actions variable + secret | rotate App key per policy |
| `CLAUDE_CODE_OAUTH_TOKEN` | claude-* workflows | repo Actions secret | TODO |
| `SNYK_TOKEN` | `task security:sast`/`sca` | repo Actions secret | TODO |
| TODO | TODO | TODO | TODO |

## Rotation & incident notes

TODO: how and how often each secret rotates; what to do if one leaks (revoke,
re-scope, rotate, scrub history). Record notable past incidents here.
