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

## Security scanning: SAST, SCA, secrets & audits

Scanning is layered across a few axes. Each check runs at a defined place — a
`task` target, a CI job, a git hook, or a GitHub-native setting — so local runs,
git hooks, and CI stay identical. **The default stack is GitHub-native + CI-local
and needs no paid service.**

| Axis | Catches | Default tool | Where it runs |
|---|---|---|---|
| **SAST** — flaws in *your own code* | injection, XSS, SSRF, path traversal, crypto/auth misuse | **CodeQL** (`codeql.yml`; JS/TS + Python) | CI, opt-in via the `FULL_SECURITY_SCAN=true` repo variable; results land in the GitHub Security tab |
| **SCA** — CVEs in *dependencies* | vulnerable third-party packages | **Dependabot alerts** + **`task security:audit`** (`pnpm audit` / `pip-audit`) | Dependabot continuous (GitHub-native); audit in the CI `security` job + `task security` locally |
| **Secrets** — committed credentials | keys, tokens, certs, `.env` | **gitleaks** (`task security:secrets`) | pre-push git hook + CI `security` job |
| **IaC** — insecure infrastructure | open security groups, public buckets, … | **checkov** (`task lint:terraform:security`) | CI `lint` job + `task check` locally (Terraform repos) |
| **Freshness** — stale dependencies | a widening exposure window | **Renovate** (`minimumReleaseAge: 3 days`) | continuous, grouped update PRs |

- **`task security`** (the CI `security` job) is `security:secrets` (gitleaks) +
  `security:audit` (dependency audit). It does **not** run Snyk.
- **CodeQL is opt-in** — its analyze jobs skip unless `FULL_SECURITY_SCAN=true`,
  which `task setup:github` sets. If CodeQL is your only SAST, confirm it is on.
- **`task setup:github`** turns on the GitHub-native layers: Dependabot alerts,
  Private Vulnerability Reporting, and the `FULL_SECURITY_SCAN` variable; the branch
  ruleset makes `verify` + `security` required checks. See
  [../CHECKLIST.md](../CHECKLIST.md).
- Which tools apply depends on the stack: SAST/SCA need code + a manifest (web/app,
  or Python for iac); IaC scanning is Terraform-only. A `general`/`docs` repo leans
  mainly on secrets + audit.

### Snyk is optional and redundant by default

The template ships Snyk targets — `task security:sast` (`snyk code test`, SAST) and
`task security:sca` (`snyk test`, SCA) — but they are **opt-in, local-only, and not
in CI**, because the default stack already covers both axes: **CodeQL** for SAST and
**Dependabot + `security:audit`** for SCA. On a normal repo Snyk is redundant — leave
it off. (`SNYK_TOKEN` is a local credential, not a CI secret; and if the Snyk GitHub
App is installed, its `code/snyk`/`security/snyk` PR checks are **not** required by
the branch ruleset — remove the app to drop them.)

### Exception: a shipped product (e.g. a B2B SaaS web app)

For a product that holds customer data, revisit the above — the redundancy stops
being waste and a **paid Snyk tier** is worth weighing:

- **Defense in depth** — a second SAST/SCA opinion matters when a miss means a
  customer-data breach, not a broken marketing page.
- **License compliance** — you are distributing a product, and **Dependabot does not
  scan dependency licences**; Snyk (or FOSSA) does.
- **Reachability** — Snyk can rank which dependency CVEs are actually reachable in
  your code, cutting noise.
- **Sales & compliance** — B2B customers send security questionnaires and may require
  SOC 2 / a vendor review, where a recognised commercial scanner is a checkbox. A
  paid tier also removes the free Snyk-Code monthly test limit.

A web app also needs layers this stack does **not** cover: **DAST** (scanning the
running app for auth bypass / IDOR / injection on live endpoints), **multi-tenant
isolation** (the top B2B web-app risk), and **container/image scanning** if it ships
images.

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

> **Free-org caveat:** org-level Actions variables/secrets only reach **private**
> repos on GitHub **Team/Enterprise**. On a **Free** org they resolve to *empty*
> in a private repo's workflows — a silent failure (e.g. an empty
> `TF_VAR_cloudflare_account_id` makes Terraform plan a resource *replacement*).
> On a Free org, set org-wide values **per-repo** instead. Public repos are
> unaffected.

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
| `CLAUDE_CODE_OAUTH_TOKEN` | claude-* workflows | repo Actions secret | re-run `claude setup-token` |
| `SNYK_TOKEN` | `task security:sast`/`sca` (optional, local-only — not in CI) | local env / 1Password | TODO |
| TODO | TODO | TODO | TODO |

> **`CLAUDE_CODE_OAUTH_TOKEN` must be an OAuth token, not an API key.** Generate
> it with `claude setup-token`; the value starts **`sk-ant-oat01-`** and bills the
> claude-* workflows to your Claude **subscription**. A raw API key
> (**`sk-ant-api03-`**) also authenticates but bills at pay-as-you-go **API
> rates** — an easy, expensive mix-up. Check the prefix before saving the secret.

### 1Password conventions (source of truth)

1Password is the source of truth for every credential, consistent across orgs,
provider accounts, and machines. The standard:

- **One vault per org** (this repo: the `evanharmon1` vault). No
  credentials in personal/shared vaults.
- **API credentials use the 1Password "API Credential" type**, named
  `<Provider> <scope-descriptor>` — e.g. `Cloudflare harmon-devkit-terraform`,
  `Cloudflare R2 harmon-devkit-tfstate-rw`. One item per credential;
  related fields live on the item rather than as separate items.
- **Field labels match the provider's own documentation, verbatim.**
  `Access Key ID` / `Secret Access Key` map 1:1 to AWS/S3 docs; `Account ID`
  and `API Token` to Cloudflare's. That means you (or an agent) can go from
  provider documentation to the 1Password item with no translation layer.
  Don't invent generic labels (`key`, `secret`) and don't normalize to a
  house case style (kebab-case, Title Case) — the provider's spelling wins.
  Common results: `API Token`, `Access Key ID`, `Secret Access Key`,
  `Default Endpoint`, `Account ID`, `App ID`, `Client ID`, `Client Secret`.
  References must match labels exactly.
- **Account-level identifiers** get a per-account item (e.g. `Cloudflare
  <org>` holding `Account ID`) so identifiers have one home too.
- **SSH keys use the 1Password SSH key type** (fields: `public key`,
  `fingerprint`, `private key`, `passphrase`).
- Repos consume credentials only through references or CI
  secrets fed from these items (`op read "…" | gh secret set …`) — never by
  copying values into other stores of record.

## Remote access (SSH, Tailscale, VNC)

- **Tailscale is the standard network layer** for remote access — homelab
  hosts and remote sites join the tailnet rather than exposing ports. Its
  OAuth client lives in the org vault (fields: `Client ID`, `Client Secret`,
  `Tailnet ID`); scope OAuth clients narrowly (e.g. auth-key creation only)
  and prefer ephemeral/pre-authorized keys minted from them.
- **SSH** keys are stored as 1Password SSH-key items (see conventions above)
  and served by the 1Password SSH agent where possible, so private keys never
  sit loose on disk.
- **VNC / screen sharing: Screens 5 is the standard client**, connecting over
  the tailnet (never an exposed VNC port); any credential it needs lives on
  the relevant 1Password item.

## Rotation & incident notes

- **Cadence**: long-lived provider tokens carry a 1-year TTL; set a calendar
  reminder ~1 week before expiry. Expired-token symptom: the CI jobs using
  the credential fail with authentication errors.
- **Rotate create → verify → revoke, never delete-first**: create the
  replacement, update 1Password and the Actions secret, prove it works (a
  trivial PR whose checks exercise the credential), then revoke the old one.
  Paired credentials (e.g. R2 key pairs) rotate as a unit — deleting the old
  token first cuts off everything that still uses it.
- **If a secret leaks**: revoke it at the provider immediately, rotate per
  above, re-scope downward if it was broader than needed, and check the
  provider's audit log for actions taken since the exposure. An allowlist
  entry stops the scanner re-flagging — it does not un-expose the key.

Record notable past incidents here.
