<!-- Update reference: basics. Step numbers (§0–§6) refer to the runbook. -->

[Update runbook](./mode-update.md) · Read this reference when its step is reached;
keep the same shell and guarded state across steps.

# Mode: Update

Bring a repo that was **already generated from harmon-init (v3+)** up to the latest
template — the repeatable "keep it in sync" path. Use this when the goal is "pull
the newest harmon-init changes into this repo," not initial setup.

Routing:

- **v3+ repo** (`.copier-answers.yml` present, with `_commit` either a `v3.x` or
  later release ref or the 40-character commit recorded by a guarded update) →
  this mode (`copier update`). For an unfamiliar full hash, resolve it against
  the canonical harmon-init remote and confirm it descends from `v3.0.0`.
- **v2 repo or never templated** → [`mode-adopt-existing.md`](./mode-adopt-existing.md)
  (v2→v3 was a breaking redesign; re-template via its Path B).
- **Just want a drift report, no changes** → run §1 and stop, or see
  [`mode-audit.md`](./mode-audit.md). Both read local/template state only, so on
  a `project_management: github` repo add §6a's and §6c's **read-only** queries
  to cover live labels, project fields, and org issue fields — a drift report
  without them is silently blind to the whole GitHub side.

The target repo is a **plain repo** — there is no special structure, no
"template-owned vs custom" split a developer must learn. Customizations live
normally in `Taskfile.yml`, `scripts/`, workflows, etc. The intelligence is here in
the skill: `copier update` does a three-way merge that pulls template improvements
*into* those files while preserving the repo's own edits; you reconcile anything that
conflicts. For copier mechanics see [`copier-gotchas.md`](./copier-gotchas.md).

`copier update` never touches **GitHub-side state**. On a repo answering
`project_management: github` the live metadata — project fields, org issue
fields, `layer:`/`domain:` labels — is a second, separate reconciliation the
update is not finished without: §6, which runs **after the PR merges**.

(It is not quite "files only" locally, either: the `task install` `_tasks` entry
is guarded on `run_task_install` alone — unlike every other entry, it carries no
`_copier_operation == 'copy'` guard — so an update on a repo that answered yes
re-runs brew deps and `lefthook install`. See §2.)

After this mode updates the template, complete the shared **Vendored skills** step
in `SKILL.md`. Any vendored skills and agents it produces ride in the standardize
PR; they are part of the deliverable, not scratch output to discard or split off.

**How to run the snippets below.** They are written to survive `bash -eu`: the
load-bearing steps carry an explicit `|| { …; exit 1; }` handler so the failure
names itself, and a command without one still stops the run under errexit, just
anonymously — so keep the handlers when you copy a block into a fresh shell.
They are not proven under `pipefail`, though: without it a mid-pipeline failure
can be masked by a succeeding final stage, so run a lifted block with
`bash -euo pipefail` care and treat the recipes' own gates and frozen-OID
cross-checks as the real backstop. Every sorted-list
comparison pins `LC_ALL=C` on both the producer and the consumer, because `sort`
and `comm` must agree on collation — an ambient UTF-8 locale orders `_` against
letters differently than byte order does (`github_org` sorts before `git_init`
under `en_US.UTF-8`, after it under `C`), so a `comm` left unpinned rejects the
`LC_ALL=C sort`ed file it was handed with `file 1 is not in sorted order`. The
pin is per command, never a one-time export at the top of a section, because
these blocks get lifted piecemeal.

---

## 0. Branch from a clean tree

```bash
cd <repo>
git switch main && git pull
git status --porcelain   # MUST be empty
git switch -c chore/update-harmon-init-v<X.Y.Z>   # e.g. chore/update-harmon-init-v3.20.0
```

**Use a version-suffixed branch name.** A bare `chore/update-harmon-init` often
already exists locally as a leftover from a prior run whose PR was
*squash-merged* — the local branch is never deleted, and its commits look
"unmerged" by SHA, so `git switch -c chore/update-harmon-init` aborts with
`a branch named '…' already exists`. Suffixing the target version
(`chore/update-harmon-init-v3.20.0`) sidesteps the collision and self-documents
the PR. (Deleting the stale local branch also works, but is destructive — prefer
the versioned name.)

**Confirm repository identity before any render.** Compare the recorded
`github_org` / `project_slug` in `.copier-answers.yml` with the live repository:

```bash
grep -E '^(github_org|project_slug):' .copier-answers.yml
gh repo view --json nameWithOwner -q .nameWithOwner
```

The YAML values must form the same `<owner>/<repo>` as `nameWithOwner`. Missing
answers or a failed repository lookup stop the update; they are not a match.
On a renamed, transferred or forked repo, stale answers would render the
Taskfile, workflows and URLs for the old target. **Stop on a mismatch:** confirm
the intended repository, correct `github_org` and `project_slug` on this update
branch, and repeat the comparison. Commit any answers correction on this branch
to restore a clean tree before §1 freezes the inputs. Keep the correction and
the subsequent render in the **same update PR**; do not defer it until §6.
Do not preview, run `diff-template.sh` or invoke `copier update` until this check
passes. Section 6a repeats it after merge before any live metadata writes.
