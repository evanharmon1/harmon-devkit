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

Scanning is layered across a few axes. GitHub-hosted CodeQL is the preferred SAST
engine where it is free: public repositories with a supported generated
workflow. Semgrep Community Edition (CE) is the free CI fallback for private
repositories and for profiles without a CodeQL workflow.

| Axis | Catches | Default tool | Where it runs |
|---|---|---|---|
| **SAST** — flaws in *your own code* | injection, XSS, SSRF, path traversal, crypto/auth misuse | **Semgrep CE** | CI and `task security:sast`; this profile has no generated CodeQL workflow |
| **SCA** — CVEs in *dependencies* | vulnerable third-party packages | **Dependabot alerts** + **`task security:audit`** | Dependabot continuous; audit in the CI `security` job + `task security` locally |
| **Secrets** — committed credentials | keys, tokens, certs, `.env` | **gitleaks** (`task security:secrets`) | pre-push git hook + CI `security` job |
| **IaC** — insecure infrastructure | open security groups, public buckets, … | **checkov** (`task lint:terraform:security`) | CI `lint` job + `task check` locally (Terraform repos) |
| **Freshness/remediation** — stale or vulnerable dependencies | a widening exposure window | **Renovate** (`minimumReleaseAge: 3 days`, Dependabot-alert remediation enabled) | continuous update and vulnerability-fix PRs |

The repository-class policy is:

| Repository class | Standard |
|---|---|
| Public, CodeQL-supported | CodeQL + Dependabot alerts/Renovate + gitleaks; no Snyk by default |
| Selected important public | Optionally add Snyk Free as a scheduled SAST/SCA second opinion; private-test quotas do not apply to public repositories |
| Private | Semgrep CE is the dependable free CI SAST baseline; keep Snyk Free manual/local by default because its Organization-wide quotas can stop scans mid-month |
| Important private | Consider paid GitHub Code Security/private CodeQL and/or paid Snyk, then decide whether per-PR scans should be merge-gating |
| Qualifying public OSS | Consider Snyk's [Secure Developer Program](https://snyk.io/open-source/) for full entitlements without usage limits |

- **`task security`** is the portable free local baseline: `security:sast`
  (Semgrep CE) + `security:secrets` (gitleaks) + `security:audit` (the
  package-manager audit). It does **not** run Snyk.
- **CI routes SAST by visibility** instead of running duplicate engines:
  this profile has no CodeQL workflow, so Semgrep CE runs for both public and
  private repositories.
- **`task setup:github`** turns on the GitHub-native layers: Dependabot alerts,
  and Private Vulnerability Reporting when the repository is public; the branch
  ruleset makes `verify` + `security` required checks. See
  [../CHECKLIST.md](../CHECKLIST.md).
- Which tools apply depends on the stack: SAST/SCA need code + a manifest (web/app,
  or Python for iac); IaC scanning is Terraform-only.

Semgrep CE is useful, open-source, and runs without a hosted account, but it is
not CodeQL-equivalent: its community analysis is principally intraprocedural
and normally has shallower data-flow coverage than CodeQL or commercial engines.
It is the private-repository floor, not a claim of full vulnerability coverage.

### Semgrep is the SAST baseline

CodeQL is deliberately omitted for this profile. The build workflow runs Semgrep
CE for public and private repositories. If the repository later gains a
CodeQL-supported application stack, set `use_codeql=true`, select its
first-party `codeql_languages`, and re-apply the template for public coverage or
for paid private GitHub Code Security coverage.

### Dependency monitoring and update ownership

Dependabot **alerts** are free for public and private repositories and are the
continuous GitHub advisory feed. Renovate owns routine dependency update PRs and
alert-remediation PRs (`vulnerabilityAlerts.enabled=true`). Do not add a
`dependabot.yml`: Dependabot update PRs would compete with Renovate. The
package-manager audit remains in CI as an immediate provider-independent check.

### Snyk second opinion and scheduling

Snyk is not installed by default and is not part of `task security` or required
PR CI. The explicit `task security:sast:snyk` (`snyk code test`) and
`task security:sca:snyk` (`snyk test --all-projects`) targets provide
manual/local second-opinion scans. Every detected dependency manifest can
consume a separate Snyk Open Source test on a private repository.

The Copier answer `snyk_scan_schedule` controls the optional workflow:

- `off` (default) — no workflow; keep `SNYK_TOKEN` local;
- `weekly` — quota-aware advisory scans, appropriate for a selected repository;
- `daily` — intended for public repositories or an accepted unlimited OSS
  project, not the ordinary private Free-plan posture.

This repository kept the default `off`, so no Snyk workflow or Actions secret is
needed. Re-render with `weekly` or `daily` only after deliberately selecting the
repository for scheduled defense in depth.

Scheduled and local CLI tests draw from the same private-repository allocation.
Weekly is the conservative cadence. Daily Snyk Code alone is about 30 tests per
repository per month, before manual tests, and SCA multiplies by the number of
manifests. The scheduled workflow is intended primarily for selected important
public repositories because Snyk's private-test limits do not apply there. A
private repository may deliberately choose weekly after estimating
Organization-wide usage, but the standard remains Semgrep CE in CI plus
occasional local Snyk. Dependabot already monitors dependency advisories
continuously, so weekly Snyk is normally enough for a second opinion.

No Snyk GitHub App is needed for local or scheduled CLI scans. Leave it off on
ordinary repositories. If installed, its PR checks (commonly
`code/snyk`/`security/snyk`) are not required by the branch ruleset; remove the
repository from the integration to eliminate them.

### Paid escalation for a high-consequence product

Choose paid controls based on the capability the product needs:

- **GitHub Code Security** supplies private-repository CodeQL and keeps findings
  and remediation in GitHub.
- **Paid Snyk** can be an alternative or a second SAST/SCA opinion, especially
  when dependency-license policy, reachability, or vendor reporting matters.
- **GitHub Secret Protection** adds server-side secret scanning, push protection,
  and governance. Gitleaks remains useful locally and in CI but does not block a
  secret before it reaches GitHub in every client/path.

DAST, tenant-isolation tests, and container/image scanning are separate,
application-specific controls. A deployed web application should evaluate them;
a library or docs repository usually should not.

## Two identities: the bot vs the operator

- **AI bot** (`evanharmon1-bot`) — runs in the primary
  devcontainer with a scoped fine-grained PAT (Write, no admin) for its in-container
  git pushes. Cannot push to or merge `main`. (CI **workflows** authenticate
  separately as the `evanharmon1-ci` GitHub App — see below.)
- **Operator** (you) — full access from the human `dev/` devcontainer or host.

### The bot's fine-grained PAT

Permissions live in
[branch-protection.md](branch-protection.md#bot-account-pat-permissions) — that
table is the source of truth. **Nothing beyond it.** The step-by-step for
creating one is [guides/bot-account.md](../guides/bot-account.md).

**Deliberately denied**, each load-bearing rather than incidental:

- **Workflows** — the bot cannot edit `.github/workflows/`. This is what stops
  the classic escalation: rewrite a workflow, let it run with Actions secrets,
  exfiltrate. It matters more than it looks, because any agent sharing the bot's
  devcontainer can read this token out of the environment — so this one
  restriction is much of what stands between a prompt-injected agent and every
  Actions secret. Assert it; do not assume it.
- **Administration** — no ruleset, settings, or bypass changes. Note the
  consequence: reading a ruleset's bypass actors needs a permission the bot does
  not have, so a preflight check that wants it must use a different identity or
  be dropped.
- **Tailscale and on-demand secret fetch** — the bot profile installs no
  1Password CLI, so there is **no path to pull arbitrary secrets on demand**, and
  no Tailscale, so no tailnet reach (see
  [guides/devcontainers.md](../guides/devcontainers.md)). Note what this does
  *not* say: the container is not secret-free. It holds whatever the env-file
  carries. That set is a **property of the 1Password Environment behind the
  env-file** — a convention you maintain, not a guarantee the profile enforces.
  Put a production credential in that Environment and it lands in the container,
  next to the agent.

### Effective access = min(collaborator grant, PAT permissions)

A fine-grained PAT is a **delegation of its owner's access** and can never exceed
it. Two independent layers must *both* allow an operation:

1. **The repo collaborator grant** on the bot account — *per repo*, and where
   granularity actually lives.
2. **The PAT's selected-repo list and permission set** — the permission set is
   **uniform across every selected repo**; there is no per-repo matrix.

So a repo where the bot is a `pull` collaborator stays read-only even though the
PAT carries `contents: write` — the grant caps the token. One PAT can therefore
back a mix of read-only and writable repos.

Two practical consequences:

- **Two levers, different jobs** — picking the wrong one is why this gets
  confusing. To change the *level* on a repo the bot still works (write → read),
  change the **collaborator grant**; a PAT cannot express per-repo levels. To stop
  *this token* reaching a repo while the bot keeps access, remove it from the PAT's
  **selected-repo list**. To revoke the bot entirely, drop the grant — and the list
  entry too, so the token stops carrying reach it cannot use.
- **Adding a repo to the PAT's list is not enough** if the bot has no access to
  it; and granting access is not enough if the repo is not in the list. Both, in
  that order.

### What a leaked bot PAT reaches

Write it down rather than re-derive it under pressure:

- **The selected repos** — at the level each collaborator grant allows, capped by
  the permission table. It can push branches, open PRs, and comment. It **cannot**
  merge `main` (ruleset + CODEOWNERS), edit workflows, or change settings.

**Read is cheap; write is the line.** Variables are read-only deliberately:
write could opt a private repository into paid CodeQL or mutate other
security/deployment switches without a PR diff. Public CodeQL does not depend on
`FULL_SECURITY_SCAN` and cannot be disabled through that variable. The read grant
is safe only because GitHub separates Secrets from Variables; if a variable ever
holds something sensitive, read becomes exfiltration. Check when adding a
variable, not forever.

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

| Secret / variable | Used by | Stored in | Rotation |
|---|---|---|---|
| `CI_APP_CLIENT_ID` (var) + `CI_APP_PRIVATE_KEY` (secret) | release-please, claude-* | repo or org Actions variable + secret | rotate App key per policy |
| `CLAUDE_CODE_OAUTH_TOKEN` | claude-* workflows | repo Actions secret | re-run `claude setup-token` |
| `GH_TOKEN` (the bot's PAT) | the devcontainer agent's `gh`/git operations | 1Password Environment → devcontainer `--env-file` | manual; re-issue before expiry ([guides/bot-account.md](../guides/bot-account.md)) |
| `SNYK_TOKEN` | optional Snyk CLI scans | local env / 1Password by default | manual |
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
