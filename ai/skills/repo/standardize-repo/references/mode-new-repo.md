# Mode: New Repo — Scaffold from harmon-init

Procedure for generating a brand-new repo from the
[harmon-init](https://github.com/evanharmon1/harmon-init) Copier template. Use
this when the destination directory does not yet exist (or is empty). To
standardize an *existing* repo instead, use the apply/update mode, not this one.

The source of truth is `harmon-init/copier.yml`. Do not invent questions, task
names, or defaults — they are derived from that file below.

## 1. Preconditions

Verify before running anything:

- [ ] **Tools installed:** `copier` (>= 9.4.0, per `_min_copier_version`),
      `git`, and — if you will create the remote or release — `gh` (GitHub CLI,
      authenticated: `gh auth status`).
- [ ] **Released template ref chosen.** Production scaffolds use the canonical
      GitHub source and a deliberately selected release tag whose template
      defines `use_coderabbit` and `use_codex_cloud_review`. A local checkout is
      needed only to inspect source
      or preview unreleased work.
- [ ] **Destination does not already exist / is empty.** Copier writes into
      `<dest>`; pick a path that is free.
- [ ] **Hidden author/org defaults are correct for you.** Identity, org info,
      and machine-specific paths live in `copier.yml` under `when: false`
      (e.g. `author_full_name`, `author_email`, `author_git_provider_username`,
      `organization`, `projects_directory`, `bunches_directory`,
      `obsidian_directory`). These are NOT asked interactively — they are baked
      in for the template owner. If you are not the template owner, fork
      harmon-init and edit those once before first use.

## 2. Generate — interactive form

The `--trust` flag is required: it allows copier to run the `_tasks` (git init,
commit, etc.) defined in `copier.yml`.

```bash
: "${HARMON_INIT_REF:?set to a released harmon-init tag whose copier.yml defines use_coderabbit and use_codex_cloud_review}"
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
HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse "$HARMON_INIT_REF^{commit}")"
git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
  grep -q '^use_coderabbit:' ||
  { echo "HARMON_INIT_REF does not support the CodeRabbit choice" >&2; exit 1; }
git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
  grep -q '^use_codex_cloud_review:' ||
  { echo "HARMON_INIT_REF does not support the Codex cloud review choice" >&2; exit 1; }
copier copy "$HARMON_INIT_SOURCE" <dest> \
  --trust --vcs-ref="$HARMON_INIT_COMMIT"
```

Choose `use_codex_cloud_review=false` and `use_coderabbit=false` at the prompts
unless this repository is deliberately opting into those external services.
Do not use a moving branch for production lineage. The guard resolves the
remote-verified release tag to
`HARMON_INIT_COMMIT` before Copier runs, so a later retag cannot change which
trusted template tasks execute.
For an unreleased template preview only, a developer may render a local checkout
with `--vcs-ref=HEAD` into a disposable destination. That preview can contain a
Copier-created throwaway commit and must not be promoted as a production scaffold.

Copier prompts for each asked question. Answer them; everything else falls back
to the hidden defaults.

## 3. Generate — non-interactive form

Supply answers with `--data key=value` (repeat per key). Side-effectful
questions all default to `no`, so omitting them is safe in CI. Add `--defaults`
to accept the default for any key you do not pass.

```bash
: "${HARMON_INIT_REF:?set to a released harmon-init tag whose copier.yml defines use_coderabbit and use_codex_cloud_review}"
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
HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse "$HARMON_INIT_REF^{commit}")"
git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
  grep -q '^use_coderabbit:' ||
  { echo "HARMON_INIT_REF does not support the CodeRabbit choice" >&2; exit 1; }
git -C ~/git/harmon-init show "$HARMON_INIT_COMMIT":copier.yml |
  grep -q '^use_codex_cloud_review:' ||
  { echo "HARMON_INIT_REF does not support the Codex cloud review choice" >&2; exit 1; }
copier copy "$HARMON_INIT_SOURCE" <dest> \
  --trust --vcs-ref="$HARMON_INIT_COMMIT" --defaults \
  --data project_name="My Project" \
  --data project_slug="my-project" \
  --data project_description="One-line description of the project" \
  --data github_org="evanharmon1" \
  --data project_type="general" \
  --data include_terraform=false \
  --data include_ansible=false \
  --data use_codeql=false \
  --data use_codex_cloud_review=false \
  --data use_coderabbit=false \
  --data ci_runner="ubuntu-latest" \
  --data license="mit" \
  --data use_release_please=true \
  --data devcontainer=true \
  --data git_init=true \
  --data github_remote_create=false \
  --data github_release_init=false \
  --data bunch_add=false \
  --data obsidian_project_add=false \
  --data run_task_install=false
```

The `use_codex_cloud_review` and `use_coderabbit` answers are introduced by
companion harmon-init changes.
Release this skill first so harmon-init can refresh its pinned vendored copy,
then merge and release the harmon-init change. Until that supporting template
release exists, this command intentionally stops at the guard above. Do not
substitute an older release (including v4.4.0 or v3.26.1): those templates
predate the question and render CodeRabbit unconditionally.

### Answerable questions (from `copier.yml`)

| Key | Type | Default | Choices / notes |
|---|---|---|---|
| `project_name` | str | — (required) | Formal name, e.g. "My Project". |
| `project_slug` | str | slugified `project_name` | lowercase, spaces → `-`. |
| `project_description` | str | `TODO: project_description` | Short description; replace the TODO. |
| `github_org` | str | `evanharmon1` (`author_git_provider_username`) | Org/user that owns the repo; drives repo URL, GHCR images, workflows. |
| `project_type` | str | `general` | `general` \| `web-astro` \| `web-app` \| `iac` \| `docs`. Drives Taskfile, CI jobs, devcontainer tooling. |
| `include_terraform` | bool | `true` iff `project_type == 'iac'` | Adds `terraform/` skeleton + terraform linting. |
| `include_ansible` | bool | `true` iff `project_type == 'iac'` | Adds `ansible/` skeleton + ansible linting. |
| `use_codeql` | bool | `true` for `web-astro` / `web-app`; otherwise `false` | Includes CodeQL SAST. Public repositories have Code Security by default; for a private/internal repo, enable GitHub Code Security first or answer `false`. |
| `codeql_languages` | multiselect | JS/TS for web; Python for supported Python/IaC selections when CodeQL is enabled | Exact CodeQL matrix; must be nonempty when `use_codeql=true` and should match real first-party source. |
| `use_codex_review` | bool | `false` | Adds local, advisory Codex review/challenge tasks and the optional Claude → Codex stop-gate. |
| `use_codex_cloud_review` | bool | `false` | Requires a terminal current-head Codex cloud result during draft shepherding. Requires `use_codex_review=true`, `use_skills_sync=true`, `universal` in `skill_categories`, a maintainer-connected GitHub integration, disabled Codex Automatic reviews, and explicit private-repository connector permission; availability and quotas depend on the maintainer's ChatGPT plan, so free-tier access is not assumed. |
| `use_coderabbit` | bool | `false` | Adds `.coderabbit.yaml`, App setup instructions, and CodeRabbit bot trust. Requires an account/App install; public OSS hosted reviews are free with rate limits, while private hosted code reviews require a paid plan after the trial. |
| `ci_runner` | str | `ubuntu-latest` | `ubuntu-latest` \| `self-hosted`. |
| `license` | str | `mit` | `mit` \| `private`. |
| `use_release_please` | bool | `true` | release-please rolling release PR + auto CHANGELOG. |
| `devcontainer` | bool | `true` | Dual-profile `.devcontainer` (AI bot + human dev). |
| `git_init` | bool | `true` | Initialize the git repo (see `_tasks`). |
| `github_remote_create` | bool | `false` | `gh repo create` (private, pushes initial state). |
| `github_release_init` | bool | `false` | Runs `task release:init` (initial release). |
| `bunch_add` | bool | `false` | Add Bunch file (macOS-only; moves to iCloud). |
| `obsidian_project_add` | bool | `false` | Add Obsidian project note to the vault (macOS-only). |
| `run_task_install` | bool | `false` | Run `task install` after generation (brew bundle + git hooks). |

Notes:
- Several defaults are *computed* from earlier answers. Setting `project_type=iac`
  flips `include_terraform`/`include_ansible` to `true` unless you override them.
- Decide `use_codeql` explicitly whenever first-party JS/TS/Python is planned. A
  generated workflow and `FULL_SECURITY_SCAN=true` configure CodeQL but do not
  prove that SARIF was accepted; private/internal repos also require the live Code
  Security capability. Review `codeql_languages` against real first-party source;
  `use_node` / `use_python` remain tooling flags rather than source evidence.
- Hidden, derived flags you do **not** answer but that follow from your choices:
  `use_node` (true for `web-astro`/`web-app`), `use_python` (true for `iac` or
  `include_ansible`), `repo_url`, `devcontainer_image`, `ci_runner_labels`.

## 4. Post-generation `_tasks` (run automatically, in order)

Because `--trust` was passed, copier runs the `_tasks` from `copier.yml`
**after** rendering, in this exact order. Each is gated on the answer in
brackets; all side-effectful ones default to `no` so `copier copy --defaults`
is CI-safe (only `git_init` runs by default, and it only touches the new
project directory):

1. `git init -b main` — when `git_init`.
2. `git add -A && git commit -m "chore: initial scaffold from harmon-init"` —
   when `git_init`. The initial commit exists so steps 3 and 5 have a `HEAD`.
   It runs *before* `task install`, so lefthook hooks are not yet installed and
   nothing intercepts this commit.
3. `gh repo create <github_org>/<project_slug> --private --source=. --push` —
   when `github_remote_create`.
4. `task install` — when `run_task_install` (brew bundle + `lefthook install`,
   plus `uv sync` / `pnpm install` if applicable).
5. `task release:init` — when `github_release_init` (tags `v0.1.0`, pushes it,
   `gh release create`). Requires the remote to exist (step 3).
6. `task util:bunch-add` — when `bunch_add` (macOS-only).
7. `task util:obsidian-add` — when `obsidian_project_add` (macOS-only).

If you left the side-effectful answers at their `no` defaults (the CI-safe,
recommended path for unattended generation), only steps 1–2 run and you finish
setup manually in the next section.

## 4a. Freeze and verify durable Copier lineage

**`--vcs-ref` does not survive into the answers file.** Copier derives `_commit`
from `git describe --tags --always` (`copier/_template.py`), so whenever a
release tag points at the checked-out commit the answers record the **tag**, not
the peeled hash you passed — even though `--vcs-ref="$HARMON_INIT_COMMIT"` was an
immutable 40-hex commit. Copier computes the peeled hash separately (`commit_hash`
→ `rev-parse HEAD`); it just never reaches `.copier-answers.yml`.

Left alone, the scaffold discards the immutable evidence the guard above just
established, and lands in the maintainer-gated legacy-baseline recovery path on
its very first update ([`mode-update.md`](./mode-update.md) §2). Freeze the tuple
to the validated commit — the same promotion update mode performs after apply:

**Run this inside `<dest>`.** §2/§3 pass the destination as an argument and leave
the shell in the *parent* directory; the only `cd` into it is down in §5. Freezing
from the parent would edit and amend whatever repo the shell is sitting in —
silently corrupting an unrelated one if it also has a `.copier-answers.yml`.
Every guard below fails closed, so a mistyped destination or a stale shell stops
here instead of promoting the wrong repo:

```bash
cd <dest> ||
  { echo "cannot enter the generated repo" >&2; exit 1; }
: "${HARMON_INIT_SOURCE:?must still hold the canonical harmon-init URL from §3}"
: "${HARMON_INIT_COMMIT:?must still hold the peeled commit validated in §3}"
test -f .copier-answers.yml ||
  { echo "generated repo has no .copier-answers.yml" >&2; exit 1; }
RENDERED_REF="$(yq -r '._commit // ""' .copier-answers.yml)"
case "$RENDERED_REF" in
"$HARMON_INIT_REF" | "$HARMON_INIT_COMMIT") ;;
*)
  echo "refusing to freeze: .copier-answers.yml records '$RENDERED_REF', not the" >&2
  echo "ref just rendered — is the shell inside the generated repo?" >&2
  exit 1
  ;;
esac
PROMOTED_ANSWERS="$(mktemp .copier-answers.yml.promote.XXXXXX)" ||
  { echo "failed to create the answers promotion file" >&2; exit 1; }
if cp .copier-answers.yml "$PROMOTED_ANSWERS" &&
  HARMON_INIT_SOURCE="$HARMON_INIT_SOURCE" \
    HARMON_INIT_COMMIT="$HARMON_INIT_COMMIT" \
    yq -i '._src_path = strenv(HARMON_INIT_SOURCE) |
      ._commit = strenv(HARMON_INIT_COMMIT)' "$PROMOTED_ANSWERS"; then
  mv "$PROMOTED_ANSWERS" .copier-answers.yml ||
    { echo "failed to atomically freeze the lineage tuple" >&2; exit 1; }
else
  rm -f "$PROMOTED_ANSWERS"
  echo "failed to freeze the scaffold lineage tuple" >&2
  exit 1
fi
```

With `git_init=true`, Copier's `_tasks` already made the scaffold commit before
this runs, so the frozen tuple has to reach history too. The **bootstrap
boundary** is separate from ordinary agent-authored changes: the **initial
base** is the commit that establishes `main` on the remote, and how it is built
— and whether the freeze folds into it or rides a draft PR — is decided by the
remote-creation profile, not by preference. The `_tasks` ordering in
`copier.yml` is what separates the cases below.

Before publishing any branch, read the generated target `AGENTS.md`. Open a
draft PR and use the draft-workbench lifecycle only when that authoritative
policy defines ready-for-review as the human handoff. If it still defines an
ordinary PR or stop-at-green handoff, the selected harmon-init release predates
the lifecycle; select a compatible release or follow the generated target
policy and report lifecycle adoption as blocked.

- **No remote yet — `github_remote_create=false` (the recommended default).**
  Nothing is published and no hooks are installed yet — Copier makes the scaffold
  commit *before* `task install` precisely so nothing intercepts it. The freeze
  **amends** the scaffold commit, so the lineage is correct from the very first
  commit. The scaffold + freeze together are the **initial base**; publish it
  directly. Because `github_remote_create=false` skipped §4 step 3, create the
  remote and make the first push yourself — `gh repo create
  <github_org>/<project_slug> --private --source=. --push` (the §4 step 3
  command) — then work through §6. `post-generation-checklist.md` picks up
  *after* that first push and owns the GitHub *settings* (it assumes the remote
  already exists — it does not create it); for a `web-astro` repo whose pre-push
  gate would fail on a bare repo, scaffold the framework **before** the first
  push, per its §3. A PR cannot predate its
  base branch — until `main` exists on the remote there is nothing for a PR to
  target — so the bootstrap base is published directly, not via a PR. Only after
  `main` is published does the draft-workbench lifecycle begin: every later
  agent-authored commit (post-generation checklist work) branches off `main`
  and opens a draft PR.
- **Remote already created — `github_remote_create=true`.** Copier's `_tasks`
  already ran `gh repo create --push`, so the scaffold (still carrying the
  tag-valued tuple) is **already published on `main`**; `github_release_init` may
  also have tagged it. That published commit is the initial base — **never
  rewrite it, and never push an agent-authored follow-up directly to `main`.**
  The freeze is the first such follow-up: **branch from `main` before committing
  it, push the branch, and open a draft PR.** `main` temporarily carries the
  tag-valued tuple until that PR merges — the deliberate cost of never rewriting
  published history; the freeze PR is the immediate next step, so the window is
  short. (Contrast the no-remote path, where the freeze lands in the unpublished
  base before anyone clones it.) Keep this PR narrow — the lineage tuple only —
  so it merges fast and closes the window; it is not the workbench for the rest
  of post-generation. The §5/§6 work (local setup, GitHub handoff, framework
  scaffolding) is not folded onto it: it proceeds normally, with any
  agent-authored commits branching off `main` into their own draft PRs per the
  target policy's draft-workbench lifecycle. The freeze is a lineage-only
  bootstrap commit, not feature work — the §5 gates (`task verify`,
  `verify-applied.sh`) verify tooling that already landed in Copier's `_tasks`
  and are unaffected by the tuple edit, so opening the freeze draft before §5
  bypasses no gate material to it.
- **Hooks installed before the freeze — `run_task_install=true`** (orthogonal to
  either profile above). `task install` runs *before* this section and installs
  lefthook while the repo is still on `main`, so the generated
  `guard:no-commit-to-main` pre-commit hook blocks any commit here — amend
  included. `--no-verify` is prohibited. The freeze goes on a feature branch with
  a draft PR (the remote-created profile's model). If there is no remote yet,
  publish the base first — create the remote and make the first push yourself
  (`gh repo create <github_org>/<project_slug> --private --source=. --push`, the
  §4 step 3 command, since `github_remote_create=false` skipped it; for a
  `web-astro` repo whose pre-push gate would fail on a bare repo, scaffold the
  framework first, per `post-generation-checklist.md` §3), then branch for the
  freeze — the unpublished base
  cannot be amended behind an installed hook.

```bash
if git rev-parse --verify HEAD >/dev/null 2>&1 &&
  ! git diff --quiet -- .copier-answers.yml; then
  git add -- .copier-answers.yml ||
    { echo "failed to stage the frozen lineage tuple" >&2; exit 1; }
  if git rev-parse --verify '@{upstream}' >/dev/null 2>&1 ||
    test -n "$(git tag --points-at HEAD)" ||
    git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
    # github_remote_create=yes published the scaffold (and github_release_init
    # may have tagged it) before this section. That commit is the initial base —
    # never rewrite published history, and never push an agent-authored
    # follow-up to main. A PR cannot predate its base branch, and main already
    # exists, so branch from main before committing the freeze, push the branch,
    # open a draft PR. Commit on the freeze branch (not main) so an installed
    # pre-commit hook does not trip: run_task_install=yes left lefthook in place,
    # but guard:no-commit-to-main blocks only commits to main, and HEAD is the
    # freeze branch once git switch -c runs — so branching here handles the
    # hooks-installed case itself, with no manual switch to a feature branch
    # first (that manual switch was what stranded the freeze on an operator
    # branch and let git switch -c branch from it, contaminating the PR).
    # origin/main is a third publication signal for the case where @{upstream}
    # is unset on the current branch (a detached or non-tracking checkout) but
    # main is published.
    FREEZE_BRANCH=chore/freeze-copier-lineage
    git switch -c "$FREEZE_BRANCH" ||
      { echo "failed to create the lineage-freeze branch" >&2; exit 1; }
    git commit -m 'chore: freeze copier lineage to the verified template commit' ||
      { echo "failed to record the frozen lineage tuple" >&2; exit 1; }
    git push -u origin "$FREEZE_BRANCH" ||
      {
        echo "freeze commit is local only — the remote still carries the" >&2
        echo "tag-valued tuple; push the branch before the first update" >&2
        exit 1
      }
    gh pr create --draft \
      --title 'chore: freeze copier lineage to the verified template commit' \
      --body 'Freeze the .copier-answers.yml lineage tuple to the verified template commit (full 40-hex hash) so the first copier update does not enter legacy-baseline recovery. See references/mode-new-repo.md §4a.' ||
      { echo "failed to open the lineage-freeze draft PR" >&2; exit 1; }
  else
    # No remote, no tag: the scaffold is still private to this machine. Fold the
    # freeze into the unpublished initial base so the first published commit
    # carries the correct lineage. (A PR cannot predate its base branch.) But if
    # run_task_install=yes installed lefthook while HEAD is main, amending here
    # trips guard:no-commit-to-main — the unpublished base cannot be amended
    # behind an installed hook. Publish the base first (create the remote and
    # make the first push yourself, the §4 step 3 command that
    # github_remote_create=false skipped), then branch for the freeze — never
    # --no-verify, never push to main.
    if test -x .git/hooks/pre-commit &&
      test "$(git rev-parse --abbrev-ref HEAD)" = main; then
      echo "lefthook is installed and HEAD is main: the scaffold is unpublished," >&2
      echo "so the freeze cannot amend it behind the hook. Publish the base first" >&2
      echo "(create the remote + first push, §4 step 3), then branch for the freeze" >&2
      echo "— never --no-verify, never push to main" >&2
      exit 1
    fi
    git commit --amend --no-edit ||
      { echo "failed to record the frozen lineage tuple" >&2; exit 1; }
  fi
fi
```

Then verify both fields — `_commit` must be a full 40-hex hash, not a tag:

```bash
grep -E '^(_src_path|_commit):' .copier-answers.yml
yq -r '._commit' .copier-answers.yml | grep -Eq '^[0-9a-fA-F]{40}$' ||
  { echo "lineage freeze failed: _commit is not a full hash" >&2; exit 1; }
```

If a repo was rendered from a local checkout, **do not rewrite only `_src_path`**.
A dirty `--vcs-ref=HEAD` render may record a temporary commit that is not reachable
from the canonical remote, leaving the next `copier update` unable to reconstruct
its base. Use that render only as a preview, then re-render/re-adopt production
from the canonical URL and a released ref. The narrow exception is a deliberately
pushed pre-release commit: first prove the recorded `_commit` is reachable from
the canonical remote, then verify and commit both lineage fields together.

## 5. After generation — local setup & self-check

```bash
cd <dest>

# If you did NOT set run_task_install=true, do it now:
task install          # Brewfile deps (+ uv sync / pnpm install as applicable) + lefthook hooks

task verify           # lint + (template's) checks — the local merge gate

# Skill self-check that the conventions actually landed:
bash <skill-dir>/assets/verify-applied.sh <dest>
```

`<skill-dir>` is the root of this skill
(`.../ai/skills/repo/standardize-repo`). `assets/verify-applied.sh` asserts the
expected artifacts are present (e.g. `Taskfile.yml`, `lefthook.yml`, the
`AGENTS.md` symlinks, `.github/workflows/`). Investigate any failure before
proceeding.

**`web-app` / `web-astro` are conventions-only stubs.** A fresh render ships the
DevOps tooling but **no application framework** — there is no `package.json`
until you scaffold one (`docs/CHECKLIST.md` §3: `pnpm create @tanstack/start` for
`web-app`, `pnpm create astro` for `web-astro`). This is expected, not a broken
scaffold: the framework-scaffolding step is the operator's next action, and the
lint/typecheck/build tasks all skip cleanly in this pre-framework window so
`task verify` stays green until then. (If you are on a template *older* than
harmon-init's build-guard fix, `task verify` / CI's build step may go red at
`pnpm build` until the framework is added — scaffold the app to clear it, or pull
the latest template.)

## 6. Hand off — GitHub setup

Finish remote/GitHub configuration via the generated checklist and this skill's
companion reference:

- In the new repo: work through `docs/CHECKLIST.md` (rendered from
  `template/docs/CHECKLIST.md.jinja`). It covers, in order: local setup → GitHub
  repo settings (branch ruleset import via the GitHub UI, Dependabot
  alerts + private vulnerability reporting, Renovate app, optional CodeRabbit app
  only when `use_coderabbit=true`, Actions
  secrets/variables, the CI GitHub App, GHCR publishing) → framework scaffolding
  for the chosen `project_type` → secrets/env → docs/meta (fill `TODO:` markers,
  confirm badges, optional `task release:init`).
- Then follow **`references/post-generation-checklist.md`** in this skill for the
  agent-driven walkthrough of that GitHub setup.
