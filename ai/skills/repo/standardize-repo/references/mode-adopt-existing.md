# Mode: Adopt harmon-init in an EXISTING repo

Apply (or re-apply) the [harmon-init](https://github.com/evanharmon1/harmon-init)
Copier template to a repo that **already has app code**. The hard rule: this is a
*standardization* pass over a living codebase, not a fresh scaffold —
**never blind-clobber existing app code.** Read each conflict, prefer merging, and
work on a feature branch the whole time.

For Copier mechanics (custom `[[ ]]`/`[% %]` jinja delimiters, released production
refs versus local-preview `--vcs-ref=HEAD`, `--trust`, side-effect answers) see
[`copier-gotchas.md`](./copier-gotchas.md). For the GitHub-side wiring after the
files land (branch ruleset import, Renovate and optional CodeRabbit apps, Actions
secrets, etc.)
see [`post-generation-checklist.md`](./post-generation-checklist.md).

---

## 0. Always branch first — never main

Direct commits to `main` are forbidden by the conventions this template installs
(lefthook `guard:no-commit-to-main` + branch ruleset). Do all adoption work on a
feature branch from a clean tree:

```bash
cd ~/git/<existing-repo>
git switch main && git pull
git status --porcelain   # MUST be empty; stash or commit first
git switch -c chore/adopt-harmon-init
```

A clean tree is also what makes conflict review legible: after the copier run,
`git diff` shows exactly what the template wants to change, file by file.

---

## 1. Detect the project type → turn it into `--data`

Copier's first decision is `project_type`, which drives the Taskfile, CI jobs, and
devcontainer tooling. Don't guess it — run the detector against the target repo:

```bash
assets/detect-project-type.sh .
```

It inspects the repo and prints the matching `project_type`, one of the five values
defined in `copier.yml`:

| `project_type` | When |
| --- | --- |
| `general`   | default — no framework/IaC signal |
| `web-astro` | Astro marketing/static site |
| `web-app`   | TanStack/React app |
| `iac`       | Terraform/Ansible infrastructure |
| `docs`      | documentation / Obsidian vault |

Feed the result straight into the copier `--data` flags. The questions you'll
normally set explicitly when adopting an existing repo (the rest fall back to
sensible `copier.yml` defaults):

```bash
PROJECT_TYPE="$(assets/detect-project-type.sh .)"

--data project_type="$PROJECT_TYPE" \
--data project_name="<Formal Project Name>" \
--data project_slug="$(basename "$(pwd)")" \
--data project_description="<short description>" \
--data github_org="<org-or-user>"
```

Defaults worth knowing so you only override what's wrong (from `copier.yml`):

- `project_slug` defaults to `project_name` lowercased with spaces → `-`.
- `include_terraform` / `include_ansible` default to **true when
  `project_type == 'iac'`**, false otherwise. Override to `true`/`false` if a
  non-iac repo nonetheless has (or wants) a `terraform/` or `ansible/` skeleton.
- `ci_runner` defaults to `ubuntu-latest` (alt: `self-hosted`).
- `license` defaults to `mit` (alt: `private`).
- `use_release_please` and `devcontainer` default to **yes**.
- `use_coderabbit` defaults to **no**. Keep it false unless this repository is
  deliberately retaining the CodeRabbit GitHub App.
- **All side-effect answers must stay `no`** when adopting: `git_init`,
  `github_remote_create`, `github_release_init`, `bunch_add`,
  `obsidian_project_add`, `run_task_install`. The repo already exists and has a
  remote/history — let those run by hand later, not as a copier `_task`. Pass
  `--defaults` to avoid prompts **and explicitly pass each one `=false`** — do
  NOT rely on copier.yml's `no` defaults. On a **re-adopt over an existing
  `.copier-answers.yml`** (every v2 repo — see Path A's v2 note), copier seeds
  defaults *from that answers file*, so a stale `true` there sails straight
  through `--defaults` and **fires the side-effect `_task`** (observed: a v2
  re-adopt's stale `github_remote_create: true` ran `gh repo create`; a stale
  `github_release_init: true` would cut a bogus `release:init` v0.1.0).
  harmon-init ≥ the side-effect-task hardening also gates these on `git_init`,
  so `git_init=false` neutralizes them on a current template — but pass them all
  `=false` to stay correct across template versions.

---

## 2. Two adoption paths

### Path A — repo was generated from this template (`copier update`)

If a `.copier-answers.yml` exists at the repo root, the repo is already linked to
the template. Update in place; copier performs a three-way merge between the old
template output, the new template output, and your current files. Follow
[`mode-update.md`](./mode-update.md) end to end: it remote-verifies and pins the
target release, collects the CodeRabbit decision (including for legacy answer
files), and passes the identical reviewed answers to preview and apply.

```bash
ls .copier-answers.yml # present → use mode-update.md
```

`--defaults` is **required non-interactively** — without a TTY copier crashes trying
to prompt (`OSError: [Errno 22]`). See [`mode-update.md`](./mode-update.md) §2.

`copier update` takes no source argument — it reuses the `_src_path` recorded in
`.copier-answers.yml`, whose `_src_path` and `_commit` must form a resolvable
lineage tuple (see [copier-gotchas.md](./copier-gotchas.md) gotcha 8; never
normalize only a local path unless the recorded commit is reachable from the
canonical remote). **Always do a full update to the deliberately selected latest
release** and pass that same ref to preview and apply. Override stale answers
with `--data key=value` as needed (e.g. `use_coderabbit` or a changed
`github_org`).
(`--vcs-ref=HEAD` is only for a *template developer* testing unreleased local
changes — never for a normal update.)

> v2-generated repos are the exception: per the harmon-init README, v3 was a
> breaking redesign (new question set, jinja delimiters, lefthook+gitleaks, manual
> releases, dual-profile devcontainer, canonical AGENTS.md). **Re-template them via
> Path B and reconcile** rather than `copier update`.

### Path B — adopt fresh (repo was NOT generated from the template)

No `.copier-answers.yml`. Copy the template *over* the existing repo. Copier will
write `.copier-answers.yml` so future runs can use `copier update`:

```bash
ls .copier-answers.yml          # absent → adopt fresh
: "${USE_CODEQL:?set USE_CODEQL=true or false after the capability review}"
: "${HARMON_INIT_REF:?set to a released harmon-init tag whose copier.yml defines use_coderabbit}"
HARMON_INIT_SOURCE=https://github.com/evanharmon1/harmon-init
git -C ~/git/harmon-init fetch "$HARMON_INIT_SOURCE" \
  '+refs/heads/main:refs/remotes/origin/main' --tags ||
  { echo "failed to refresh harmon-init from origin" >&2; exit 1; }
REMOTE_TAG_OBJECT="$(
  git -C ~/git/harmon-init ls-remote --exit-code "$HARMON_INIT_SOURCE" \
    "refs/tags/$HARMON_INIT_REF" |
    awk 'NR == 1 { print $1 }'
)" ||
  { echo "HARMON_INIT_REF is not a tag published by origin" >&2; exit 1; }
test -n "$REMOTE_TAG_OBJECT" &&
  test "$(git -C ~/git/harmon-init rev-parse "refs/tags/$HARMON_INIT_REF")" = "$REMOTE_TAG_OBJECT" &&
  git -C ~/git/harmon-init merge-base --is-ancestor "$HARMON_INIT_REF^{commit}" origin/main ||
  { echo "HARMON_INIT_REF must exactly match a release tag on origin/main" >&2; exit 1; }
git -C ~/git/harmon-init show "$HARMON_INIT_REF":copier.yml |
  grep -q '^use_coderabbit:' ||
  { echo "HARMON_INIT_REF does not support the CodeRabbit choice" >&2; exit 1; }
copier copy --trust "$HARMON_INIT_SOURCE" . \
  --vcs-ref="$HARMON_INIT_REF" --defaults --overwrite \
  --data project_type="$PROJECT_TYPE" \
  --data project_name="<Formal Project Name>" \
  --data project_slug="$(basename "$(pwd)")" \
  --data github_org="<org-or-user>" \
  --data use_codeql="$USE_CODEQL" \
  --data codeql_languages="$CODEQL_LANGUAGES" \
  --data use_coderabbit=false \
  --data git_init=false \
  --data github_remote_create=false --data github_release_init=false \
  --data bunch_add=false --data obsidian_project_add=false --data run_task_install=false
  # ↑ pass EVERY side effect =false (see §1). On a v2 RE-adopt copier seeds
  #   defaults from the stale .copier-answers.yml, so they do NOT "default to no".
```

The `use_coderabbit` answer is introduced by the companion harmon-init change.
Release this skill first so harmon-init can refresh its pinned vendored copy,
then merge and release harmon-init. Until that supporting template release
exists, the guard above intentionally blocks adoption. Older releases (including
v4.4.0 and v3.26.1) render CodeRabbit unconditionally. Local `--vcs-ref=HEAD`
adoption is for a disposable preview only, never the production apply: dirty
local renders can record a throwaway `_commit` that no later remote update can
resolve.

Set `USE_CODEQL` and `CODEQL_LANGUAGES` deliberately before rendering. Use
`true` only when supported first-party JS/TS or Python source is present and Code
Security is available (public repositories have it by default; inspect
private/internal repositories with the read-only check in
[`mode-audit.md`](./mode-audit.md), drift class G). Otherwise use `false`; do not
render a workflow whose SARIF upload cannot succeed. The language selection must
be nonempty when enabled and match the real source.

`--defaults` is **required non-interactively** (no TTY → `OSError: [Errno 22]`), and
because copier can't prompt per-file, `--overwrite` makes the run deterministic
(write every template-owned file; reconcile afterward from git — see below).

**Pass `--data git_init=false` explicitly.** `git_init` defaults to `yes`, and the
`git init` / scaffold-commit `_tasks` fire on `_copier_operation == 'copy'` — which
adopt **is** — so without it copier attempts a `git add -A && git commit` over the
existing repo's history. (harmon-init ≥ the "repo-update hardening" change makes
those `_tasks` idempotent so this is a no-op anyway, but pass it for older templates.)

### Non-interactive reconciliation (the safe pattern for a mature repo)

`--overwrite` resets **every** template-owned file to the new render, clobbering
local customization. On a clean feature branch that is fully recoverable — reconcile
from git rather than hand-merging conflict markers:

1. **Survey the damage:** `git diff --stat main` — most entries are pure tooling
   (accept the template version). Identify the files that carried real local
   customization (`git show main:<f>` vs the working tree).
2. **Restore customized files** wholesale from `main`:
   `git checkout main -- <Taskfile.yml> <renovate.json> <.gitignore> …`. The repo
   was likely already close to current (hand-synced), so this loses little template
   improvement while preserving every customization.
   - **`.github/CODEOWNERS` is access control — never silently reduce it.** The
     template renders it from the single `code_owner` answer (`* @code_owner`),
     which can't hold a second owner or a team, so the adopt render drops any
     extras. `git checkout main -- .github/CODEOWNERS` (or merge the owners) and
     **confirm any owner change with the user** — dropping a code owner is a
     security regression, not a tooling sync. (harmon-init ≥ the CODEOWNERS-freeze
     change keeps it via `_skip_if_exists`, and `verify-applied.sh` FAILS if an
     owner present on `main` is missing post-adopt — but check it by hand too.)
     For a user-confirmed replacement, pass
     `--ack-codeowner-change @old=@new` to `verify-applied.sh`, repeating the
     exact mapping for each dropped owner. The verifier checks that `@old`
     existed on `main` and is now absent, that `@new` is present now, and
     rejects stale, extra, malformed, or non-materialized mappings. There is no
     blanket access-control bypass.
   - **If you restore a customized `Taskfile.yml` but keep the template's
     workflows, reconcile the contract.** The template's `.github/workflows/*`
     delegate to `task` targets (e.g. `test:tasks`, `test:hooks`,
     `test:devcontainer:permissions`) that a pre-template Taskfile won't have.
     `task verify` will **not** catch the gap — CI will. List every target the
     adopted workflows call and ensure each exists, porting the missing targets +
     their `scripts/*.sh` from the template:
     `grep -rhoE '(run:[[:space:]]*|^[[:space:]]*|&&[[:space:]]*)task +[a-z][a-z0-9:_-]*' .github/workflows/ | sed -E 's/.*task +//' | sort -u`.
     `verify-applied.sh` §3c enforces this (see [mode-audit.md](./mode-audit.md)
     drift class L).
3. **Keep** the template version for uncustomized tooling **and all applicable
   additive new files** (docs scaffold, release-please, helper scripts,
   `.copier-answers.yml`; CodeQL only when `use_codeql=true` and the live
   capability supports it).
4. **Canonicalize AGENTS.md** — fold the old real guidance (often the pre-existing
   real `CLAUDE.md`) into `AGENTS.md`; leave `CLAUDE.md`/`GEMINI.md`/
   `.github/copilot-instructions.md` as the symlinks copier wrote (§4.1).
5. **Confirm:** `diff-template.sh .` should now list only the files you deliberately
   restored. Each remaining `DRIFT` must be an intentional customization you can name.

Caveat: `.copier-answers.yml` now records the new `_commit`, so a future
`copier update` will **not** re-offer this version's improvements to the files you
restored. That's correct when the divergence is deliberate (e.g. a repo that keeps
its own CI auth model / runners / workflow tiers); otherwise backport the specific
improvement now.

---

## 3. Overwrite / conflict handling — review every conflict

When copier touches a file that already exists with different content it prompts
per file. The cardinal rule: **never blind-clobber existing app code; prefer
merging.**

- **Conflict prompt (`copier copy` over existing files):** copier asks to
  overwrite each differing file `(y/n)`.
  - **App/source code, business logic, real READMEs, existing docs with content:**
    answer **n** (keep yours). Reconcile by hand afterward.
  - **Pure tooling/config the template owns** (`Taskfile.yml`, `lefthook.yml`,
    `.github/workflows/*`, `.editorconfig`, `.gitleaks.toml`, `renovate.json`,
    `commitlint.config.mjs`, devcontainer): generally accept the template version,
    then re-apply any genuine local customizations on top.
- **`copier update` (Path A):** conflicts surface as `.rej` files / inline merge
  markers. Resolve like a git merge — `grep -rn '^<<<<<<<\|^=======\|^>>>>>>>' .`
  and `find . -name '*.rej'`, then edit each so both the template's intent and the
  repo's real content survive.
- After resolving, **read the full diff before staging**:
  `git add -A -N && git diff` — confirm nothing under app/source paths was
  silently overwritten, and no copier variable leaked (search for the literal
  `[[`, `[%`, or unresolved `TODO: project_description`).

When in genuine doubt about a specific file, keep the existing version and leave a
`TODO:` note rather than discarding working code.

---

## 4. Reconciliation steps specific to existing repos

These are the recurring drifts observed across existing repos. Walk each one
after the copier run:

1. **AGENTS.md is canonical; everything else symlinks to it.** The template ships
   `AGENTS.md` as the real file with `CLAUDE.md`, `GEMINI.md`, and
   `.github/copilot-instructions.md` as symlinks → `AGENTS.md`. Existing repos
   frequently have it backwards (e.g. `CLAUDE.md` is the real file). Flip it:

   ```bash
   # make AGENTS.md the single source of truth, then symlink the rest to it
   ln -sf AGENTS.md CLAUDE.md
   ln -sf AGENTS.md GEMINI.md
   ln -sf ../AGENTS.md .github/copilot-instructions.md   # note: ../ from .github/
   ```

   **Fold the old file's *substantive* guidance** — architecture, directory
   structure, real commands, project-specific conventions — into `AGENTS.md`
   *before* replacing it with a symlink. Don't settle for a thin fold that keeps
   only the one-line project blurb (and a `TODO: run /init`): the old file's real
   content is the whole point of the merge. Then confirm the tool excludes are
   in place so
   linters don't choke on the symlinks: `lefthook.yml`'s prettier hook must
   `exclude` `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md`
   (these are explicit excludes in the template's `lefthook.yml`).
   Verify: `ls -l CLAUDE.md GEMINI.md .github/copilot-instructions.md` should all
   show `-> AGENTS.md` / `-> ../AGENTS.md`.

2. **Align the docs layout** to the template's tree. Specs live at **root
   `specs/`** (move any `docs/specs/` → `specs/`); tests at **root `tests/`**.
   Ensure these exist (the template seeds them): `docs/README.md`,
   `docs/glossary.md`, `docs/conventions.md`, `docs/guides/` (incl.
   `onboarding.md`), `docs/architecture/` (incl. `tests.md`, `security.md`,
   `ci-cd.md`), `docs/product/` (incl. `roadmap.md`, `vision.md`),
   `docs/decisions/` (ADRs, with the seed `0001-record-architecture-decisions.md`),
   `docs/runbooks/` (**plural**), and `docs/CHECKLIST.md`. Don't delete existing
   docs with real content — fold them into the standard locations.

3. **Leave YAML extensions alone.** Do not rename `.yaml`↔`.yml`. Each tool
   keeps its own conventional extension (`Taskfile.yml`, `.yamllint.yml`;
   GitHub Actions accepts either) — homogenizing extensions across the repo is
   not a goal. After renaming, update any branch-ruleset required-check contexts
   that referenced the old job names (see `post-generation-checklist.md`).

4. **Add `# renovate:` annotations to tool pins.** Inline tool-version pins in
   workflows must carry a renovate annotation so updates are automated and pins
   stop diverging across repos. Match the template's format exactly — the comment
   sits on the line directly above the pinned `VERSION=` assignment. Example from
   the template's `build.yml` gitleaks install:

   ```bash
   # renovate: datasource=github-releases depName=gitleaks/gitleaks extractVersion=^v?(?<version>.+)$
   GITLEAKS_VERSION=8.24.3
   ```

   Do the same for any other un-annotated pins you find (go-task, shellcheck,
   shfmt, actionlint, node versions). Pin third-party GitHub Actions by commit SHA
   with a trailing version comment.

5. **Other recurring fixes** (apply if present): consolidate duplicate Claude
   workflows (`claude-*-max.yml` → the base `claude-plan/implement/review.yml`);
   align the explicit CodeQL selection/languages with real supported source and
   live capability (or use Semgrep CE alone); replace legacy Snyk PR CI with the
   manual/local default or the explicit weekly/daily advisory schedule; drop any
   bump-on-merge `release.yml` in favor of release-please; de-bloat a legacy
   `Brewfile`; make scripts portable to macOS bash 3.2 (no `mapfile`, no
   `grep -P`).

6. **v2→v3 re-adopt cleanup (the v2 question set predates lefthook/gitleaks).**
   After the Path B render, **delete the superseded v2 artifacts** the template no
   longer ships: `.pre-commit-config.yaml` (→ lefthook); `check_for_pattern.sh` +
   any `test/whisperConfig.yml` (→ gitleaks); a v2 `package.json` (eslint/prettier
   stubs) and `requirements.txt` (whispers/pre-commit deps) on a non-node repo;
   `.ansible-lint` when ansible isn't in the pipeline; and the old `build.yaml` /
   `security.yml` / `validate.yml` workflows the template's `build.yml` supersedes.
   Untrack a now-gitignored root `todo.md` and drop a stale
   `<old-slug>.code-workspace`. **`node_modules/` gotcha:** an older `general`
   (`use_node=false`) `.gitignore` did NOT ignore `node_modules/`, so a v2 repo
   carrying one needs it added (now fixed in harmon-init — present in every
   profile). Restore the rich `README.md` from `main` and update its stale refs
   (badges `validate.yml`/`build.yaml` → `build.yml`; `task validate` → `task
   verify`; drop `.pre-commit-config.yaml`/`.ansible-lint` mentions). Fold the old
   real `CLAUDE.md` into `AGENTS.md` per step 1.

   **Prettier config: keep the repo's, not the template's (web-astro/web-app).**
   The template ships `prettier.config.cjs` assuming astrowind-era devDeps
   (`prettier-config-standard`, `prettier-plugin-tailwindcss`) that a mature
   repo's `package.json` may not have — `lint:prettier` then dies with "Cannot
   find module" — and its style (`semi: false`, `singleQuote`) would reformat
   the entire codebase. On adopt: **delete the rendered `prettier.config.cjs`
   and keep the repo's own `.prettierrc.cjs`**, then run one
   `prettier --write` pass over the template-shipped JS/JSONC files
   (`commitlint.config.mjs`, `scripts/*.mjs`, `.markdownlint-cli2.jsonc`,
   `*.code-workspace`) so they conform to the repo's style. Expect
   `diff-template.sh` to report those files as DRIFT + `prettier.config.cjs`
   as MISSING — both intentional.

   **Preserve a truthful `.copier-answers.yml` lineage tuple.** A dirty local
   `--vcs-ref=HEAD` preview can record a throwaway `_commit` that exists in no
   clone. Do not relabel that output by changing `_src_path` or substituting a
   nearby release tag: either action makes the recorded base differ from what
   was rendered. Re-run the production adoption from the canonical URL at the
   reviewed release. Only a deliberately pushed pre-release commit is eligible
   for promotion, after proving `_commit` is reachable from the canonical remote
   and verifying both lineage fields together.

   **Four traps that block the first commit/push after a v2→v3 render:**
   (a) **Stale pre-commit.com hook** — deleting `.pre-commit-config.yaml` leaves the
   installed `.git/hooks/pre-commit` behind, which blocks *every* commit with
   "No .pre-commit-config.yaml file was found"; run **`pre-commit uninstall`**,
   then `task install:hooks` (lefthook) to wire the v3 hooks. Two things make this
   recur: the stub is often **globally seeded** by git's `init.templateDir`
   (`~/.git-template/hooks/pre-commit`, from a past `pre-commit init-templatedir`),
   so it lands in *every* clone/`git init` — even repos with no
   `.pre-commit-config.yaml`, where it **silently no-ops** (`--skip-on-missing-config`)
   and hides next to lefthook's hooks; and `lefthook install` backs it up to
   `pre-commit.old` while `lefthook uninstall` **restores** it, so a bare `rm` isn't
   durable. Fix for good: `grep -rl 'generated by pre-commit' .git/hooks` → `rm` the
   matches, then (if it holds only that stub) `git config --global --unset
   init.templateDir` + `rm -rf ~/.git-template`. All local — `.git/hooks/*` is never
   tracked, so there is nothing to commit or push. (b) **gitleaks
   scans full history** — adopting it surfaces pre-existing leaks (a committed
   key/cert/`.env`) that fail the pre-push hook *and* CI; for each KNOWN finding
   add its fingerprint (`gitleaks detect --report-format json` → `.Fingerprint`)
   to **`.gitleaksignore`** AND **rotate the secret** (urgent if the repo is
   public — the allowlist stops re-flagging, it does not un-expose the key).
   (c) **Mis-shebanged scripts** — a `#!/bin/sh` script that uses bash features
   (`&>`, `function`, arrays) makes `shfmt` parse it as POSIX and fail; fix the
   shebang to `#!/usr/bin/env bash`.
   (d) **`.meta/*.md` symlinks fail the prettier hook** — v2's
   `obsidian_project_add`/`bunch_add` left `.meta/<name>.md` (and `.bunch`) as
   symlinks into the Obsidian vault / iCloud; v3 *tracks* `.meta/`, so the
   first commit stages them and lefthook's prettier hook passes the `.md`
   symlink explicitly — prettier errors on explicit symlinks (same failure
   class as the `CLAUDE.md`/`GEMINI.md` excludes). Add `".meta/*.md"` to the
   prettier hook's `exclude:` list in `lefthook.yml`.

   Path B's `--overwrite` also **resets `.gitignore`** to the template's —
   re-merge the repo's custom ignores (binary/cache patterns like `*.dll`,
   `.output/`) from `main`, but NOT what v3 now tracks (`*.code-workspace`,
   `.vscode/settings.json`, `.meta/`).

7. **Scope the repo's linters past reference/example content.** A repo that
   *houses* example or vendored content — a boilerplate library (`templates/`,
   `snippets/`), copy-paste Windows scripts, an agent-skill source — should not be
   held to its own operational lint standard for that content (the same reason the
   template excludes `.claude/**`). Patterns that worked: `lint:shell`'s
   `SHELL_FILES` adds `':!:templates/' ':!:snippets/'`; `scripts/lint-hygiene.sh`
   skips `*.cmd`/`*.bat` (Windows files use CRLF by convention). NB a `SHELL_FILES`
   exclusion does **not** apply when lefthook passes `{staged_files}` via
   `CLI_ARGS`, so add a matching lefthook `exclude:` if staged edits to that
   content must skip too. A **chezmoi** dotfiles source is a special case: it is
   **both** a chezmoi source directory **and** a harmon-init-templated repo, so its
   repo-maintenance files sit at the root next to the dotfiles — and chezmoi must
   not deploy any of them to `$HOME`. Handle it explicitly:
   - **Root `Brewfile` for repo tooling, separate from the deployed one.** The repo
     needs a root `Brewfile` (its own toolchain, for `task install` / `status.sh`),
     kept distinct from the `private_Brewfile` chezmoi renders to `~/Brewfile` (the
     full dev-machine set). `diff-template.sh` reports the root `Brewfile` as
     `MISSING` because chezmoi names its copy `private_Brewfile` — a **false
     MISSING**; add a root `Brewfile`, don't "restore" one.
   - **`.chezmoiignore` every repo-maintenance file.** Files not starting with `.`
     are NOT auto-ignored, so `AGENTS.md`, `GEMINI.md`, `DESIGN.md`, `CHANGELOG.md`,
     `commitlint.config.mjs`, `lefthook.yml`, `Taskfile.yml`, `Brewfile`,
     `renovate.json`, `release-please-config.json`, and the `scripts/`, `specs/`,
     `tests/` dirs would otherwise be deployed to `$HOME` on the next
     `chezmoi apply`. Add them all to `.chezmoiignore` and verify with
     `chezmoi status` (an `A` line = would be added to `$HOME`) / `chezmoi managed`.
   - The `.tmpl` files themselves are safe: they aren't `*.sh`/`*.yml` (so
     `lint:shell`/`yamllint` skip them) and `{{ .chezmoi.* }}` Go-templates don't
     match the copier marker scan. The one lint snag is app-managed configs missing
     a trailing newline (e.g. `private_karabiner.json`, `private_dot_mackup.cfg`) —
     append one, and expect it to **recur**: the app rewrites its config without a
     newline and the next `chezmoi re-add` re-imports it, failing `lint:hygiene`
     again (bit harmon-dotfiles twice, 2026-06/07). Re-append on each occurrence;
     a durable per-file lint-hygiene ignore is a harmon-init backlog item.
   - **If the source uses chezmoi `git.autoCommit`/`autoPush`, reconcile it with
     lefthook.** A chezmoi source that auto-commits to `main` collides with the
     template hooks head-on — the `no-commit-to-main` guard blocks the commit and
     commitlint rejects chezmoi's non-Conventional message ("Update dot_zshrc"). To
     keep the auto-push convenience, **trim `lefthook.yml` to the gitleaks `pre-push`
     only** (drop `pre-commit` + `commit-msg`), so secrets are still caught before
     they leave — an intentional, documented divergence (expect a future
     copier-update conflict; keep the trimmed version). Also beware the **`git add .`
     sweep**: chezmoi's `autoCommit` stages the *whole* source tree, so an uncommitted
     repo-tooling edit sitting in the clone gets swept into a dotfile auto-commit and
     pushed — keep the tree clean, or guard `chezmoi re-add` to skip when
     `git status --porcelain` is non-empty.

---

## 5. Verify, then commit on the branch

Run the same gate the template installs, then the skill's applied-state check:

```bash
task install        # one-time: brew deps + lefthook hooks (safe to run now)
task verify         # the merge gate: lint → (build) → validate
assets/verify-applied.sh .
```

`task verify` runs `check` (all linters[, typecheck], parallel), an optional
`build` for node projects, then `validate`. `verify-applied.sh` confirms the
adoption actually took (canonical AGENTS.md + symlinks, docs layout, `.yml`
extensions, renovate annotations, no leaked copier vars). Fix everything they flag.

**git-lfs repos: `lefthook install` shadows git-lfs's pre-push.** If the repo uses
git-lfs, installing lefthook overwrites `.git/hooks/pre-push` with lefthook's
(gitleaks) and moves git-lfs's aside to `pre-push.old` — so the git-lfs pre-push that
uploads LFS objects on push **stops running, silently** (the push still succeeds, but
LFS blobs may never upload). Detect with `grep -l git-lfs .git/hooks/*` after install;
if git-lfs's pre-push was shadowed, make lefthook run it too (add a `pre-push` command
that invokes `git lfs push`, or chain `pre-push.old`) and confirm with
`git lfs push --dry-run origin HEAD` that objects still upload.

Then stage, review the **full** diff one more time, and commit on the feature
branch with a Conventional Commit message (types enforced by commitlint):

```bash
git add -A
git diff --cached            # final read — no clobbered app code, no leaked [[ ]]/[% %]
git commit -m "chore: adopt harmon-init conventions"
```

Never bypass hooks with `--no-verify`. Open a PR (code-owner review + `verify` and
`security` status checks are required) — do not merge to `main` directly. Finish
the GitHub-side wiring per [`post-generation-checklist.md`](./post-generation-checklist.md).
