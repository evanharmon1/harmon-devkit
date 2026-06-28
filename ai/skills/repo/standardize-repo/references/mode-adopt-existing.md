# Mode: Adopt harmon-init in an EXISTING repo

Apply (or re-apply) the [harmon-init](https://github.com/evanharmon1/harmon-init)
Copier template to a repo that **already has app code**. The hard rule: this is a
*standardization* pass over a living codebase, not a fresh scaffold —
**never blind-clobber existing app code.** Read each conflict, prefer merging, and
work on a feature branch the whole time.

For Copier mechanics (custom `[[ ]]`/`[% %]` jinja delimiters, the load-bearing
`--vcs-ref=HEAD`, `--trust`, side-effect answers) see
[`copier-gotchas.md`](./copier-gotchas.md). For the GitHub-side wiring after the
files land (branch ruleset import, Renovate/CodeRabbit apps, Actions secrets, etc.)
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
template output, the new template output, and your current files:

```bash
ls .copier-answers.yml          # present → use update
copier update --trust --defaults
```

`--defaults` is **required non-interactively** — without a TTY copier crashes trying
to prompt (`OSError: [Errno 22]`). See [`mode-update.md`](./mode-update.md) §2.

`copier update` takes no source argument — it reuses the `_src_path` recorded in
`.copier-answers.yml`, which must be a **resolvable git URL** (see
[copier-gotchas.md](./copier-gotchas.md) gotcha 8; normalize it first if it's a
relative/local path). **Always do a full update to the latest released version** —
plain `copier update` goes to harmon-init's newest tag and three-way-merges the whole
delta into your files; don't scope it to a specific intermediate version. Override
stale answers with `--data key=value` as needed (e.g. a changed `github_org`).
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
copier copy --trust ~/git/harmon-init . --vcs-ref=HEAD --defaults --overwrite \
  --data project_type="$PROJECT_TYPE" \
  --data project_name="<Formal Project Name>" \
  --data project_slug="$(basename "$(pwd)")" \
  --data github_org="<org-or-user>" \
  --data git_init=false \
  --data github_remote_create=false --data github_release_init=false \
  --data bunch_add=false --data obsidian_project_add=false --data run_task_install=false
  # ↑ pass EVERY side effect =false (see §1). On a v2 RE-adopt copier seeds
  #   defaults from the stale .copier-answers.yml, so they do NOT "default to no".
```

`--vcs-ref=HEAD` is **mandatory** here when `~/git/harmon-init` is a local path:
without it copier silently renders the latest git tag and ignores
committed-but-untagged + uncommitted template work.

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
3. **Keep** the template version for uncustomized tooling **and all additive new
   files** (docs scaffold, codeql/release-please, helper scripts, `.copier-answers.yml`).
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

These are the recurring drifts harmon-init exists to fix (source:
`harmon-init/docs/sourceRepoFollowUps.md`). Walk each one after the copier run:

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

   Merge any unique guidance from the old real file into `AGENTS.md` *before*
   replacing it with a symlink. Then confirm the tool excludes are in place so
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
   keeps its own conventional extension (`Taskfile.yml`, `.coderabbit.yaml`,
   GitHub Actions accepts either) — homogenizing extensions across the repo is
   not a goal.

   (Note `.coderabbit.yaml` is intentionally `.yaml` — leave it.) After renaming,
   update any branch-ruleset required-check contexts that referenced the old job
   names (see `post-generation-checklist.md`).

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
   add `codeql.yml` if missing and the repo uses node/python; drop any
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

7. **Scope the repo's linters past reference/example content.** A repo that
   *houses* example or vendored content — a boilerplate library (`templates/`,
   `snippets/`), copy-paste Windows scripts, an agent-skill source — should not be
   held to its own operational lint standard for that content (the same reason the
   template excludes `.claude/**`). Patterns that worked: `lint:shell`'s
   `SHELL_FILES` adds `':!:templates/' ':!:snippets/'`; `scripts/lint-hygiene.sh`
   skips `*.cmd`/`*.bat` (Windows files use CRLF by convention). NB a `SHELL_FILES`
   exclusion does **not** apply when lefthook passes `{staged_files}` via
   `CLI_ARGS`, so add a matching lefthook `exclude:` if staged edits to that
   content must skip too. A **chezmoi** dotfiles source needs none of this: its
   `.tmpl` files aren't `*.sh`/`*.yml` (so `lint:shell`/`yamllint` skip them) and
   `{{ .chezmoi.* }}` Go-templates don't match the copier marker scan — the only
   snag is app-managed configs missing a trailing newline (e.g.
   `private_karabiner.json`), which just need one appended.

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
