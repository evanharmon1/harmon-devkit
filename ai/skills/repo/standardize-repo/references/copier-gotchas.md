# Copier gotchas (load-bearing mechanics)

The `harmon-init` template (`/Users/evan/git/harmon-init`) sets custom jinja
delimiters and several copier behaviors that, if ignored, produce *silently wrong*
renders — no error, just missing or stale output. Respect every rule below when
authoring `template/**`, editing `copier.yml`, or running `copier copy` / `copier
update` against a local checkout of the template.

Authority: these are derived from `copier.yml` (`_envops`, `_preserve_symlinks`,
`_tasks`, `_min_copier_version`), `scripts/test-template.sh`, `.gitignore`, and the
"Critical Copier Gotchas" section of `AGENTS.md`. `_min_copier_version` is `9.4.0`.

---

## 1. `--vcs-ref=HEAD` is load-bearing for local-path templates

**Symptom:** You copy from a local path, then your uncommitted (or committed-but-
untagged) template edits don't appear in the output — copier renders an *old* repo
state with zero warning.

**Why:** When the template source is a git repo, `copier copy <path> <dest>` renders
the **latest git tag**, not your working tree. All uncommitted AND committed-but-
untagged work is silently ignored.

**Rule:** Always pass `--vcs-ref=HEAD` when rendering from a local checkout for
testing. With it, copier auto-includes dirty **and** untracked changes via a
throwaway `wip` commit in a temporary clone (you'll see a `DirtyLocalWarning`). Your
real working tree is never touched. `scripts/test-template.sh` always passes
`--vcs-ref=HEAD` — mirror that for any manual render of work-in-progress.

```bash
copier copy --trust --vcs-ref=HEAD /path/to/harmon-init /path/to/dest
```

---

## 2. Custom jinja delimiters — `[[ ]]`, `[% %]`, `[# #]`

**Symptom:** Standard `{{ }}` / `{% %}` syntax in a `.jinja` file passes through
unrendered (because GitHub Actions `${{ }}`, go-task `{{.VAR}}`, and lefthook
`{staged_files}` are meant to survive verbatim), or a stray blank line / eaten
newline corrupts the rendered file.

**Why:** `copier.yml`'s `_envops` remaps the delimiters specifically so CI/task/hook
syntax needs zero escaping:

| Construct | Delimiter |
|-----------|-----------|
| variable  | `[[ var ]]` |
| block     | `[% if x %]` … `[% endif %]` |
| comment   | `[# comment #]` |

`trim_blocks: true` and `lstrip_blocks: true` are also set, so block tags on their
own line don't leave blank lines.

**Rules:**

- Use `[[ ]]` / `[% %]` / `[# #]` for *all* templating. Leave `${{ }}`, `{{.VAR}}`,
  `{staged_files}` untouched — they render verbatim.
- **Inside `.sh.jinja` (and any shell), use POSIX single-bracket tests `[ ... ]`,
  not bash `[[ ... ]]`.** A bash `[[` opens a jinja variable delimiter and breaks the
  render. (See `template/[% if devcontainer %].devcontainer[% endif %]/post-create.sh.jinja`,
  which uses `if [ -d ... ]`.) This also keeps scripts portable to macOS bash 3.2.
- **An inline `[% endif %]` at end-of-line eats the following newline.** When the
  `endif` sits at the end of a content line (not on its own line), write
  `[% endif +%]` to preserve the newline. Real examples:
  `template/renovate.json.jinja:106` (`}[% endif +%]`) and
  `template/.github/workflows/build.yml.jinja:84`
  (`- name: Lint[% if use_node %] + typecheck[% endif +%]`). A standalone
  `[% endif %]` on its own line is fine (see `template/.gitignore.jinja`).

---

## 3. `_preserve_symlinks: true` keeps the AGENTS.md symlinks

**Symptom:** Without it, copier dereferences symlinks and the generated project gets
three duplicate copies of the instructions file instead of links.

**Why:** `copier.yml` sets `_preserve_symlinks: true` so `CLAUDE.md`, `GEMINI.md`,
and `.github/copilot-instructions.md` stay **symlinks** to the canonical `AGENTS.md`
(copilot's link targets `../AGENTS.md`).

**Rule:** Edit only `AGENTS.md`; never edit the three symlinks. After any render,
`scripts/test-template.sh` asserts each is a symlink to the right target — keep it
that way when authoring template files.

---

## 4. Side-effectful answers default to `no` (CI-safe `--defaults`)

**Symptom:** `copier copy --defaults` in CI would otherwise create a GitHub repo, cut
a release, or move files into iCloud / an Obsidian vault.

**Why & rule:** These questions in `copier.yml` all default to **no** so
`copier copy --defaults` is side-effect-free:

- `bunch_add` (macOS-only; moves a file to iCloud)
- `github_remote_create` (`gh repo create --private --push`)
- `github_release_init` (`task release:init`)
- `run_task_install` (`task install` — brew bundle + git hooks)
- (`obsidian_project_add` is likewise default `no`)

When adding any new question whose `_tasks` command has an external side effect,
**default it to `no`**. The only exception is `git_init` (default `yes`) because it
touches only the new project directory.

---

## 5. Unanchored `.meta` (or a global `~/.gitignore`) silently drops `template/.meta`

**Symptom:** A dirty render is missing the Bunch / Obsidian notes under
`template/.meta/` — they never make it into the output, with no error.

**Why:** Copier's dirty-tree path clones the template with `git clone --no-checkout`
(empty index) and then runs `git add -A` to build the throwaway `wip` commit. Because
the index is empty, gitignore rules apply **even to already-tracked files**. An
**unanchored** `.meta` pattern (in this repo's `.gitignore` or a developer's global
`~/.gitignore`) therefore matches `template/.meta` and excludes it from the wip
commit — so it's absent from the render.

**Rule:** Anchor ignore patterns to the repo root and re-include the template's copy
with negations. This repo's `.gitignore` does exactly that:

```gitignore
/.meta                  # anchored — was matching template/.meta unanchored
!template/.meta/
!template/.meta/**
```

If a render is missing `template/.meta` content, suspect a global `~/.gitignore` with
an unanchored `.meta` and add the negations above.

---

## 6. Conditionally-named files aren't compiled unless an answer makes the name non-empty

**Symptom:** A syntax error inside a `[% if ... %]`-named file ships silently —
nothing flags it — because no answer profile ever renders that file.

**Why:** Copier skips any file whose **rendered name is empty**. Files named with a
condition (e.g. `template/[% if use_release_please %]release-please-config.json[% endif %].jinja`,
`template/[% if include_terraform %]terraform[% endif %]/`,
`template/.meta/[% if bunch_add %]Code Project - [[ project_name ]].bunch[% endif %].jinja`,
`template/.github/workflows/[% if github_org != author_git_provider_username %]project-automation.yml[% endif %].jinja`)
are never even compiled by jinja until some answer set makes that name non-empty.

**Rule:** Every `[% if ... %]`-named file/directory must be covered by at least one
profile in `scripts/test-template.sh` (`minimal | web | iac | full | meta`), or its
jinja/syntax errors never surface. When you add a new conditionally-named file,
ensure an existing profile turns its condition on — or extend the profiles — and run
`task test:template:all`.

---

## 7. The initial scaffold commit must run before remote-create / release-init

**Symptom:** `gh repo create --push` or `task release:init` fails because `HEAD`
doesn't exist yet.

**Why:** The `_tasks` in `copier.yml` are ordered so that, when `git_init` is on,
`git init -b main` is immediately followed by:

```yaml
git add -A && git commit -m "chore: initial scaffold from harmon-init"
```

Both the `github_remote_create` task (`gh repo create ... --push`) and the
`github_release_init` task (`task release:init`) require `HEAD` to exist. This commit
also runs **before** `task install`, so lefthook hooks aren't installed yet and
nothing intercepts it.

**Rule:** Preserve this `_tasks` ordering — `git init` → initial scaffold commit →
remote create / release init / task install. `scripts/test-template.sh` asserts the
rendered repo has a commit (`git rev-parse HEAD`) whenever `_tasks` ran; don't add a
remote/release task ahead of the scaffold commit.

---

## 8. `_src_path` must be a resolvable git source for `copier update`

**Symptom:** `copier update` aborts with **`Updating is only supported in
git-tracked templates`** — even though harmon-init *is* a git repo. The repo can be
generated and pass every gate, yet never accept a template update.

**Why:** `copier update` has no source argument — it reuses the `_src_path` recorded
in `.copier-answers.yml`, which is whatever path was passed to the original `copier
copy`. If the repo was scaffolded with a **relative or machine-local path** (e.g.
`copier copy harmon-init <dest>` run from `~/git`, recording `_src_path:
harmon-init`), that string doesn't resolve to a git repo from the target's directory
later, so copier can't find a git-tracked template to diff against.

**Rule:** Record a **globally resolvable** `_src_path` — the GitHub URL
`https://github.com/evanharmon1/harmon-init` (works on any machine and in CI). When
adopting/auditing an existing repo whose `_src_path` is relative or local-absolute,
normalize it **before** running `copier update`:

```bash
# one-time fix, committed; copier overwrites _src_path on its next run anyway
yq -i '._src_path = "https://github.com/evanharmon1/harmon-init"' .copier-answers.yml
```

This is independent of `--vcs-ref` (gotcha 1): `--vcs-ref` picks *which ref* of the
source to render; `_src_path` is *where the source is*. A local checkout is fine for
testing WIP, but the **committed** `_src_path` should be the URL so the repo stays
updatable everywhere.

---

## Quick checklist when touching the template

- Rendering local WIP to test? → `--vcs-ref=HEAD`.
- Generated repo must stay updatable? → committed `_src_path` is the GitHub URL, not
  a relative/local path (gotcha 8).
- New templating? → `[[ ]]` / `[% %]` / `[# #]`; POSIX `[ ]` in shell; `[% endif +%]`
  inline.
- New side-effect question? → default `no`.
- New conditionally-named file? → cover it with a `test-template.sh` profile.
- New ignore pattern? → anchor to `/` and negate `template/` copies.
- After any `copier.yml` / `template/**` change → `task test:template:all` must pass.
