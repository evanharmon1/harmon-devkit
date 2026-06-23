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
~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/detect-project-type.sh .
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
PROJECT_TYPE="$(~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/detect-project-type.sh .)"

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
  `--defaults` (with the `--data` overrides above) to lock the rest down
  non-interactively, or answer interactively and explicitly decline each one.

---

## 2. Two adoption paths

### Path A — repo was generated from this template (`copier update`)

If a `.copier-answers.yml` exists at the repo root, the repo is already linked to
the template. Update in place; copier performs a three-way merge between the old
template output, the new template output, and your current files:

```bash
ls .copier-answers.yml          # present → use update
copier update --trust --vcs-ref=HEAD
```

`copier update` takes no source argument — it reuses the `_src_path` recorded in
`.copier-answers.yml`. When that `_src_path` is a **local** harmon-init checkout
(which it is for repos adopted via Path B's `copier copy ~/git/harmon-init`),
pass `--vcs-ref=HEAD` so update renders your working tree. Omitting it renders the
latest **local git tag** of that checkout — silently dropping any
committed-but-untagged + uncommitted template work, the exact trap described in
`copier-gotchas.md`. Use `--vcs-ref=HEAD` unless you deliberately want the last
tagged release. Override stale answers with `--data key=value` as needed (e.g. a
changed `github_org`).

> v2-generated repos are the exception: per the harmon-init README, v3 was a
> breaking redesign (new question set, jinja delimiters, lefthook+gitleaks, manual
> releases, dual-profile devcontainer, canonical AGENTS.md). **Re-template them via
> Path B and reconcile** rather than `copier update`.

### Path B — adopt fresh (repo was NOT generated from the template)

No `.copier-answers.yml`. Copy the template *over* the existing repo. Copier will
write `.copier-answers.yml` so future runs can use `copier update`:

```bash
ls .copier-answers.yml          # absent → adopt fresh
copier copy --trust ~/git/harmon-init . --vcs-ref=HEAD \
  --data project_type="$PROJECT_TYPE" \
  --data project_name="<Formal Project Name>" \
  --data project_slug="$(basename "$(pwd)")" \
  --data github_org="<org-or-user>" \
  # ...remaining --data / --defaults, side-effect answers = no
```

`--vcs-ref=HEAD` is **mandatory** here when `~/git/harmon-init` is a local path:
without it copier silently renders the latest git tag and ignores
committed-but-untagged + uncommitted template work.

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

---

## 5. Verify, then commit on the branch

Run the same gate the template installs, then the skill's applied-state check:

```bash
task install        # one-time: brew deps + lefthook hooks (safe to run now)
task verify         # the merge gate: lint → (build) → validate
~/git/harmon-devkit/ai/skills/repo/standardize-repo/assets/verify-applied.sh .
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
