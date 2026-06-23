---
name: standardize-repo
description: >-
  Apply the harmon-init Copier template's conventions (DevOps tooling, CI/CD, lint,
  security, git hooks, Taskfile) to a repo. Use whenever the user wants to "apply
  harmon-init", "scaffold a new repo with my conventions", "set up a new project",
  "adopt the template", "bring this repo up to my standards", "standardize this repo",
  or "audit this repo against my standards / check what's missing". Covers three
  modes: scaffolding a brand-new/empty repo, retrofitting an existing repo with git
  history, and auditing a repo for drift from the standards. Trigger it even if the
  user doesn't say the word "skill".
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Task, WebFetch
---

# Standardize Repo (apply harmon-init conventions)

Bring a repo in line with the **harmon-init** Copier template — the shared baseline
of DevOps tooling, CI/CD, linting, secrets scanning, lefthook git hooks, and a
`Taskfile.yml` task runner. harmon-init is the **template** repo of harmon-stack
(siblings: harmon-devkit, harmon-dotfiles, harmon-ops, harmon-infra); this skill is
how an agent *consumes* that template to scaffold new repos or standardize existing
ones. harmon-init is NOT an application — it is used via
[Copier](https://copier.readthedocs.io/en/stable/), so the heavy lifting is
`copier copy` / `copier update`, not hand-copying files.

## Preconditions

Verify these before doing anything; stop and tell the user if one is unmet.

- **copier** installed — `copier --version` (needs `>= 9.4.0`, per `_min_copier_version`).
- **harmon-init** cloned locally at `~/git/harmon-init`. If missing:
  `git clone https://github.com/evanharmon1/harmon-init ~/git/harmon-init`.
- **task** (go-task) on PATH — `task --version` — for the verification gate.
- **gh** authenticated (`gh auth status`) — only needed for the GitHub side-effect
  steps (remote create, release init). Not required for local scaffolding.

## Mode routing

Detect the situation, then follow the matching reference file end to end.

| Situation | Mode | Reference |
| --- | --- | --- |
| Target dir is empty / does not exist yet (new project) | **new-repo** | `references/mode-new-repo.md` |
| Target is an existing repo **with git history** (retrofit) | **adopt-existing** | `references/mode-adopt-existing.md` |
| User says "audit" / "check" / "what's missing" / "bring up to standard" / drift report | **audit** | `references/mode-audit.md` |

If it is ambiguous (e.g. a non-empty dir that is not a git repo), ask the user which
mode they want rather than guessing — `copier copy` vs `copier update` behave very
differently.

## Cardinal copier rules (read before running any copier command)

These are load-bearing. Full rationale and edge cases in `references/copier-gotchas.md`.

- **Always pass `--vcs-ref=HEAD` when the template source is a local path.** Without
  it, copier renders the **latest git tag** of harmon-init and silently ignores all
  uncommitted *and* committed-but-untagged work. With it, copier auto-includes
  dirty/untracked changes via a throwaway commit in a temp clone
  (`DirtyLocalWarning`) — the working tree is never touched.
- **Side-effectful answers default to `no`** in `copier.yml` (`github_remote_create`,
  `github_release_init`, `bunch_add`, `obsidian_project_add`, `run_task_install`).
  Leave them off unless the user explicitly asks; only flip them on with confirmation.
- **Run non-interactively** with `--data key=value` for known answers and
  `--defaults` for the rest, so runs are reproducible and CI-safe. Use `--trust`
  (the template has `_tasks`). Example shape:

  ```bash
  copier copy ~/git/harmon-init ./new-project \
    --vcs-ref=HEAD --trust \
    --data project_name="My Project" --data project_type=general --defaults
  ```

- **Validate after every apply.** Re-running `copier` or changing answers can churn
  files — confirm the result with the verification step below before committing.

The asked questions live in `~/git/harmon-init/copier.yml` (e.g. `project_name`,
`project_slug`, `project_description`, `github_org`, `project_type`
[general / web-astro / web-app / iac / docs], `include_terraform`, `include_ansible`,
`ci_runner`, `license`, `use_release_please`, `devcontainer`, `git_init`). Read that
file to confirm names/choices/defaults before scaffolding — do not invent answers.

## Standards catalog

The authoritative, itemized list of what "standardized" means — every tool, config
file, Taskfile target, hook, and CI workflow the template provides, and how to check
each — is **`references/standards-catalog.md`**. The audit mode and any manual
retrofit work off that catalog. Treat the generated template output (and that
catalog) as the source of truth, not memory.

## Verification

After applying any mode, run the bundled check:

```bash
assets/verify-applied.sh <target-repo-dir>
```

It confirms the expected files/tooling landed and then runs the repo's own gate
(`task verify` = lint + template/output checks; `task check` for lint only;
`task install:hooks` to wire lefthook). Report what passed and surface any gaps
against `references/standards-catalog.md`. Never bypass hooks (`--no-verify` is
prohibited); commit on a feature branch and open a PR — no direct commits to `main`.
