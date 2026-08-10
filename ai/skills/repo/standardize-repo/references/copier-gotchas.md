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

**Rule:** Production scaffolds use the canonical URL and the remote-verified
`HARMON_INIT_REF` flow in `mode-new-repo.md`. Update mode additionally resolves
the target tag once, resolves the recorded `_commit` once, and puts both commits
in a read-only clone with no remote. Copier may re-describe a commit to a tag,
but every nested clone then uses the same frozen local tag mapping instead of
refetching mutable remote state. Process-scoped Git URL rewrites bind Copier's
canonical source URL to that clone. The destination's ignored
`.copier-guarded-update/` state directory preserves the original answers and
checkout identity so interrupted runs remain recoverable.
Legacy tag-only baselines require the explicit recovery path in
`mode-update.md`; their original commit cannot be proven retroactively. Pass
`--vcs-ref=HEAD` only when rendering from a local checkout into a disposable
preview/test. With it, copier auto-includes
dirty **and** untracked changes via a
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

**Rule:** Record a durable lineage tuple: a globally resolvable `_src_path`
(`https://github.com/evanharmon1/harmon-init.git`) **and** an `_commit` reachable
from that source. Never normalize only `_src_path` without first proving the
recorded commit exists on the canonical remote. A dirty local `--vcs-ref=HEAD`
render may record a Copier-created throwaway commit that no remote clone can
resolve; changing the path disguises rather than repairs that broken base. Use the
local render only as a preview, then re-render/re-adopt from the canonical URL at
a released ref. If a deliberately pushed pre-release commit is used, verify its
remote reachability and commit both lineage fields together.

This is independent of `--vcs-ref` (gotcha 1): `--vcs-ref` picks *which ref* of the
source to render; `_src_path` is *where the source is*. A local checkout is fine for
testing WIP, but the **committed** `_src_path` should be the URL so the repo stays
updatable everywhere.

---

## 9. `copier update` never adopts a file your baseline already shipped

**Symptom:** a template file the repo does not have stays absent through every
update, forever. No conflict, no prompt, no line in the output. `diff-template.sh`
keeps reporting it `MISSING` and each `copier update` keeps not fixing it, so the
gap looks like a tooling bug and gets shrugged off as one.

**Why:** not because the diff is empty — that explanation is wrong and it
predicts the wrong things. Copier renders the template at the recorded `_commit`
(the baseline) and at the target ref and reconciles the two against the repo,
but before it applies anything it computes which paths the subproject **no
longer has** and *excludes them from creation*. The absence is honoured as a
decision, whatever the two renders say about the file's content.

The difference is testable, and this repo's suite tests it: take a file both
renders ship whose content **changed** across the range, delete it from the
repo, and update. A diff-driven merge has a real hunk to apply and nothing to
apply it to, so it would conflict or recreate the file. Copier does neither — the
file stays absent, the update returns clean, and no `.rej` or `.orig` appears.
The exclusion is explicit, not emergent.

That is not a failure. Reading an absence as the user's own deletion and
preserving it is precisely what an update is supposed to do, and it is the same
behavior that stops an update from re-adding every file a repo has deliberately
removed. The one documented way back in is `_skip_if_exists`, below — which is
exactly what you would expect of an explicit exclusion list: it needs an
explicit exception.

The trap is what happens next. A successful update rewrites `_commit` to the
target, so the *next* update's baseline already contains the file too — and
diffs it against a repo that still lacks it, to the same conclusion. Every
subsequent update reaches the same answer for the same reason. **For any path
both renders ship, the absence is a permanent opt-out**, and nothing in the repo
records that anyone chose it. A file removed in a hurry three versions ago is
indistinguishable from one nobody ever noticed was missing.

**"Both renders" is the whole condition**, and it is worth being exact about
which absences it covers, because the loose version of this rule is wrong. A
file the template gained *after* your recorded baseline is **target-only**: the
baseline→target diff does add it, so the update creates it and there is no trap
at all. What is permanent is everything the template already shipped **at your
baseline** — whether you deleted it, or adopted the template mid-life and never
had it, or declined it once and let an update reset the baseline over the top.
That last case is how a target-only file turns into a permanent one: the update
creates it, you remove it before committing, and from the next update on it sits
in both renders. The mechanism does not care how the absence arose, only that
both sides of the diff agree the file exists.

**`_skip_if_exists` is the one carve-out, and it runs the other way.** The
option means "do not overwrite this when it is already there" — so on a path
that is **absent**, it does not preserve the absence, it renders the file fresh.
A both-renders path covered by `_skip_if_exists` is therefore *not* permanent:
the update recreates it, untracked, with the target's content. harmon-init lists
`CHANGELOG.md`, `*.code-workspace`, `.github/CODEOWNERS`,
`.release-please-manifest.json`, and `.devcontainer/related-repos.txt` there —
content owned by another generator or by the consumer. Read the target
`copier.yml` rather than trusting that list, and treat `.github/CODEOWNERS`
specially: it encodes who must review, the render writes it from one answer, and
a repo that widened its owners gets the single-owner version back without a
word. [`mode-update.md`](./mode-update.md) §1 classifies these
`created` (noted `recreated`) and §4 confirms they landed.

**Rule:** adopt deliberately or record the decline — never let an absence stand
unexamined just because the tooling is quiet about it. `MISSING` is a decision
you owe an answer to, not a warning you can wait out. The guarded update makes
that mechanical: [`mode-update.md`](./mode-update.md) §1 classifies every path
the two renders disagree on (or agree on and the repo lacks) into
`nonadoption-report.tsv` by rehearsing the apply against a scratch copy —
`nonadopt-both` is the permanent class, `created` is one the apply wrote — and §5
requires the survivors in the PR body with a disposition per row. In audit mode,
where there is only one render, treat every whole-render `MISSING` as a
permanent non-adoption candidate: that render is at the repo's own `_commit`, so
everything it reports is by definition a path the baseline ships —
[`mode-audit.md`](./mode-audit.md) §3 drift class K.

---

## Quick checklist when touching the template

- Rendering local WIP to test? → `--vcs-ref=HEAD`.
- Generated repo must stay updatable? → `_src_path` is canonical **and** `_commit`
  is reachable from it; never rewrite the path alone (gotcha 8).
- New templating? → `[[ ]]` / `[% %]` / `[# #]`; POSIX `[ ]` in shell; `[% endif +%]`
  inline.
- New side-effect question? → default `no`.
- New conditionally-named file? → cover it with a `test-template.sh` profile.
- New ignore pattern? → anchor to `/` and negate `template/` copies.
- A repo is `MISSING` a file its baseline already shipped? → no update will ever
  restore it; adopt it or record the decline (gotcha 9). Two exceptions, both
  created by the update: a file added upstream *after* that baseline is
  target-only, and a path listed under `_skip_if_exists` is rendered fresh
  whenever it is absent.
- After any `copier.yml` / `template/**` change → `task test:template:all` must pass.
