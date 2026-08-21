# Conventions

How we do things in Harmon DevKit — the conventions a contributor (human or
AI) should follow. Most are **enforced** by git hooks (lefthook) and CI; the rest
is the residue a linter can't mechanize. A **flat lookup** — grep for the rule
you need rather than reading it through. `AGENTS.md` is the AI quick-reference;
it points here.

## Commits & git

- **Conventional Commits**, enforced by commitlint at the `commit-msg` hook.
  Allowed types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
  `refactor`, `revert`, `style`, `test`. Format
  `type(scope): subject`, imperative mood.
- **Subject and body lines ≤ 100 characters** (config-conventional).
- **Breaking changes:** `feat!:` (or a `BREAKING CHANGE:` footer) — drives a
  major bump.
- **Feature branches only.** Direct commits to `main` are blocked by the
  `guard:no-commit-to-main` pre-commit hook and the branch ruleset. Land changes
  via a PR; code-owner review and the `verify` + `security`
  checks are required.
- **Never bypass hooks** (`--no-verify` is forbidden) — fix the underlying issue.
  In the devcontainer a Claude Code hook actively blocks `--no-verify` and
  validates commit messages.
- Run **`task verify`** before pushing; the pre-push hook runs secret scanning
  (and type/IaC checks where applicable).

## Issues & tracked work

The mechanics are enforced by the [`track-work`](../ai/skills/universal/track-work/)
skill at authoring time and by the **tracking guard**
(`tracking-guard.yml` → `guard:closing-keywords`, unit-tested by
`task test:track-work`) at PR time.

- **`Refs #N` is the default in a PR body.** It links without closing. Use a
  closing keyword (`Closes`/`Fixes`/`Resolves`) only when the PR resolves the
  issue **entirely** — GitHub obeys it at merge, and anything left unticked
  survives only inside a closed issue, off every backlog.
- **The title and the commit messages are closing vectors too.** Squash-merge
  makes the title the commit subject, and this repo's
  `squash_merge_commit_message` is `COMMIT_MESSAGES`, so commit messages become
  the squash body — plus they land verbatim under `rebase`/`merge`. The guard
  checks all three.
- **An issue with unticked items must not be auto-closed.** Tick each criterion
  as you verify it *during* implementation (`assets/tick-criteria.sh`), not when
  writing the PR body — a PR that resolves its issue should reach `gh pr create`
  already tick-complete, leaving `Refs` for genuinely partial work. Editing the
  title or body re-runs the guard;
  ticking the issue's boxes does not (it watches pull-request events), so that
  path needs a manual re-run. Never bypass it.
- **The guard is advisory, not blocking.** The ruleset requires only `verify` and
  `security`, so a red Tracking Guard is visible but does not stop a merge — same
  as the release-content guard. Treat a red one as a stop anyway; making it
  required means first removing its fork/bot job skips, since a skipped job never
  reports and a required check that never reports blocks the PR forever.
- **Never close across repos.** Write `Refs owner/repo#N`. A bare `#123` always
  means *this* repo — a number that crosses a repo boundary carries its repo
  everywhere it is written or verified.
- **Re-read an issue before describing it** (`gh issue view <n> --json
  state,stateReason,title,body,comments`), including one you read earlier in the
  same session — your own merged PRs can resolve items in it. `state` is `CLOSED`
  for every closed issue; `stateReason` is what says whether that was a decline,
  a delivery, or a pointer elsewhere.
- **Follow-up work is filed in the repo that owns the code, immediately**, with a
  provenance line back to where it was found. Not batched into a tracking issue,
  not appended to a doc; both have failed here, in opposite directions.
- **Search the repo you are filing into before filing there** — `gh issue list
  --repo <target> --state all --limit 200 --search "<phrase>"`. The bullet above
  moves the target away from the tracker you have open, so the habitual duplicate
  check answers a question nobody asked.
- **Close reasons are factual claims.** `completed` means it was built;
  `not planned` covers declined, obsolete and **superseded**, with a comment
  naming what replaced it; `duplicate` is its own reason — the work is live
  elsewhere rather than declined — and **must** name the canonical issue in the
  comment, because GitHub records the reason and not the target.
- **Perishable claims carry a `## Verify` command.** An issue citing `file:line`
  or "currently does X" needs a command that re-establishes whether it still
  holds; without one a stale citation is indistinguishable from a live one.
  Stronger still, where a test harness exists: ship a failing assertion instead
  of a description — it cannot rot, and it closes when the test passes.
- **Acceptance criteria are `- [ ]` task-list items.** An issue with no task list
  gives the closing-keyword guard nothing to read, so the protection silently
  does not apply.

## Worktrees

- **`.worktrees/` is THE location** for linked git worktrees, and it is
  gitignored. Lint globs and security-scan excludes already assume it; put a
  tree anywhere else and those excludes stop applying.
- **Create them with `task worktree:new -- <name>`**, never a bare
  `git worktree add`. The task (`scripts/worktree-new.sh`) creates or attaches
  the branch — including one that exists only on a remote, which it tracks
  rather than recreating — installs **this tree's** dependencies, proves the
  git hooks fire inside it, prints the ready path, and rolls the tree back if
  any of that fails. A new branch is based on the **main worktree's HEAD**, not
  the caller's — and when that branch's configured upstream resolves, the base
  is first verified against it: behind means the fresh upstream tip is used
  (announced), diverged refuses with a `--base` remedy, so a tree never
  silently starts from stale history. Running the task from inside a worktree
  does not silently stack the new branch on that one; `--base HEAD` stacks
  deliberately. Creating a genuinely new branch also probes every configured
  remote for a same-named branch first — a branch that exists remotely is
  tracked, never recreated — so that path needs the remotes reachable: an
  offline run fails closed with the fix in the message, and an explicit
  `--base <ref>` skips the remote lookup entirely.
  `--branch` and `--no-install` cover the rest.
  One entrypoint means a second agent session, a terminal multiplexer, or a
  human all get the same tree instead of each rediscovering the setup.
- **Remove them with `task worktree:rm -- <name>`** (`--force` to discard
  uncommitted work). It refuses on uncommitted changes **and** on ignored local
  files such as a `.env` — `git worktree remove` counts modified and untracked
  files but not ignored ones, so a plain remove would take those with it.
  Edits hidden by `skip-worktree`/`assume-unchanged` refuse too, a deleted
  flagged file included. In a sparse checkout an absent flagged path is exempt
  only when the tree's active sparse rules exclude it (asked via
  `git sparse-checkout check-rules`); on git < 2.42, which lacks
  `check-rules`, the exemption deliberately stays per-tree rather than
  failing closed, so clean sparse worktrees remain removable on e.g. macOS
  system git (harmon-init#919).
  Ignored *directories* (`node_modules/`, `.venv/`, `dist/`) do not block it:
  `worktree:new` reinstalls them, and refusing there would make `--force`
  routine and so meaningless. It also prunes the registry and clears leftover
  gitlink directories — stale ones make later tooling treat a dead path as a
  live checkout.
- **Sweep leftover admin records with `task clean:worktree-records`**, never a
  raw `git worktree prune` — a stale record's detached HEAD can be the only
  thing keeping a commit alive, and a raw prune makes it unreachable. The task
  removes records only (never a worktree directory), refuses records carrying
  single-copy state, and pins a detached commit as
  `refs/session-cleanup/pin/<record>` *before* the record goes; pins are
  settled only by explicit human action (`task audit:session-artifacts` lists
  the pending ones). Removal serializes with `worktree:new`/`worktree:rm`
  through the shared lifecycle lock — for trees under the blessed
  `.worktrees/` layout; a tree from a raw `git worktree add` elsewhere is
  outside that protocol — as is a `git worktree lock` racing the removal
  itself — which is the documented residual for keeping to the tasks.
- **A fresh worktree has no `node_modules`/`.venv`.** Working files are per-tree,
  so dependency install is per-tree too; that is what `worktree:new` runs and
  why "it worked in the main checkout" is not evidence.
- **The Node installer is selected from the repo's own signals** — a
  `package.json` alone proves "Node repo", never "pnpm repo". Precedence:
  the `packageManager` field in `package.json` (the Corepack declaration)
  wins — including over a stale foreign lockfile, when its own manager's
  files are present; otherwise exactly one manager's files at the tree
  root — `pnpm-lock.yaml`/`pnpm-workspace.yaml` → pnpm,
  `package-lock.json`/`npm-shrinkwrap.json` → npm, `yarn.lock` → Yarn,
  `bun.lock`/`bun.lockb` → Bun. Every contradiction fails loudly before
  any install touches the tree: files from two managers with no
  declaration, a declaration whose manager has no files here while other
  managers' files exist (installing would write a second lockfile), an
  unsupported `packageManager` value, and a declared numeric major that
  the installed binary does not match (a drifted major can rewrite the
  committed lockfile; corepack-shimmed binaries report the pinned version
  and pass). When the selected manager's own lockfile exists the install
  runs in its immutable mode (`npm ci`, `--frozen-lockfile`, Yarn Berry
  `--immutable`), so lockfile drift fails and rolls back instead of
  rewriting a committed file; with no lockfile, plain `install` runs and
  may create one. A bare `package.json` with no signal skips the install
  with a note — declare `packageManager` to make it deterministic.
- **Never pass `-c core.hooksPath=.git/hooks` to git in a worktree.** In a
  linked worktree `.git` is a **file**, not a directory, so that path resolves
  to nothing and commits run **hook-less and silently**. Git's own defaults are
  correct: hooks live in the shared `$GIT_COMMON_DIR/hooks` and
  `git rev-parse --git-path hooks` resolves them from any tree. Plain
  `git commit` is the right command.
- **Devcontainer smoke tests are an explicit exclusion.** Only the workspace
  folder is mounted, and a linked worktree's `.git` file points outside it, so
  post-create sees no repository. `scripts/devcontainer-smoke.sh` detects this
  and says so instead of failing opaquely. Run it from the main checkout, or
  build the image and `docker run` it directly.

## Task runner (Taskfile)

- Tasks are named **`group:action`** — the group/domain comes first, the action
  is the leaf: `lint:shell`, `lint:typescript`, `test:e2e`, `security:secrets`,
  `install:hooks`, `status:git`. **Never action-first** (`typescript:lint`,
  `yaml:lint`).
- Pipeline order is **`check → build → validate → test → security`**, with
  `verify` (the definition-of-done gate — check + validate + test) and
  `ci` (full — verify + security) as the aggregates. `check` is the
  fast inner-loop/hook gate.
- **`task ci` mirrors CI** — every check the build workflow *gates on* that can
  run locally belongs there. The one exception is a check that needs **CI-only
  infrastructure**: document it in `AGENTS.md` as an exception instead of faking
  it locally.
- **`lint:*` and `check` are read-only gates** — they report and fail, never
  modify files. All auto-fixing lives in **`task format`**, **`task format:file
  -- <path>`**, and **`task fix`** (= format then lint). Pre-commit hooks run the
  read-only `lint:*`, so a failing check **blocks the commit and tells you** to
  run `task format` rather than silently rewriting your tree.
- Formatters (e.g. Prettier, Black, shfmt, `terraform fmt`, markdownlint) expose
  a check side in `lint:*` and a write side in `format`; pure analyzers (e.g.
  shellcheck, actionlint, yamllint, ESLint) are check-only by design.
- **Workflows delegate to `task` targets** so local hooks, CI, and humans run
  identical commands — the Taskfile is the single source of truth. Don't
  reimplement command logic in a workflow or a hook.

## Code style

- Indentation: **2 spaces** by default; **4 spaces** for Python, Terraform, and
  Shell (`.editorconfig`). Final newline; trim trailing whitespace (except
  Markdown/MDX).

## TODOs

- Mark unfinished work with `TODO: <description>` — the literal `TODO:` prefix, in
  code and docs alike, so it stays greppable (`rg 'TODO:'`).

## YAML, Markdown & shell

- **YAML:** 2-space indent, linted by yamllint. Use whichever extension
  (`.yml` or `.yaml`) each tool conventionally uses (e.g. `Taskfile.yml`,
  `.yamllint.yml`) — don't normalize extensions repo-wide.
- **Markdown:** markdownlint — ATX headings, no duplicate headings, emphasis and
  strong markers consistent within a file; line-length and first-line-heading
  rules are off.
- **Shell:** must pass `shellcheck --severity=error` and `shfmt -d`, and stay
  portable to macOS bash 3.2 (no `mapfile`, no `grep -P`).

## CI / GitHub Actions

- **Pin third-party actions by full commit SHA** with a trailing `# vX.Y.Z`
  comment, and annotate tool versions with `# renovate: datasource=…` so
  Renovate keeps them current.
- Third-party CI/SaaS integrations that require an account, app installation,
  trial, or payment must be explicit opt-ins that default off. Document free-tier
  and private-repository limitations before adding them to generated output.
- **Least-privilege `permissions:`** per job; never log secrets.
- CI authenticates as the **`evanharmon1-ci` GitHub App** (short-lived
  tokens), not a PAT — see [architecture/security.md](architecture/security.md).

## Secrets

- Local env comes from **1Password** (`op run` / `op inject`); CI reads GitHub
  Actions secrets. `gitleaks` runs on pre-push and in CI.
- When generating or rotating secrets, keep the value **on stdin** and use the
  destination-only helpers: `task secret:set:1p VAULT=… ITEM=… FIELD=…
  [SECTION=…]` for existing 1Password fields, `task secret:set:gh NAME=…
  REPO=owner/repo` for GitHub repo secrets. Never pass secret values as command
  arguments, `--body` values, exported env vars, or Taskfile vars — they end up
  in shell history and process listings.

## Docs & AI steering

- **`AGENTS.md` is the single source of truth** for AI guidance; `CLAUDE.md`,
  `GEMINI.md`, and `.github/copilot-instructions.md` are **symlinks** to it —
  edit only `AGENTS.md`.
- **Doc filenames are kebab-case** (`branch-protection.md`, `ci-cd.md`). The
  conventional uppercase project files keep their names: `README.md`,
  `AGENTS.md`, `DESIGN.md`, `CHANGELOG.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `LICENSE`, `CHECKLIST.md`.
- Documentation layering: `docs/product/` (why/where) · `specs/` (what to build)
  · `docs/architecture/` (how) · `docs/decisions/` (ADRs, numbered `0001-`) ·
  `docs/guides/` (build it) · `docs/runbooks/` (operate it). Folder landing
  pages are `README.md`.

## Releases

- Releases are intentional via **release-please**: merge the rolling release PR
  to cut the tag, GitHub release, and CHANGELOG entry. `task release:*` remains a
  manual override. Nothing auto-releases on a normal merge.
- **The commit type drives the release.** release-please reads the type to pick
  the CHANGELOG section and bump: `feat` → **Features** (minor), `fix` → **Bug
  Fixes** (patch), `feat!` / `BREAKING CHANGE:` → major. The rest (`build`,
  `chore`, `ci`, `docs`, `perf`, `refactor`, `revert`, `style`, `test`) don't cut
  a release on their own — they ride along in the next one.
- **On a squash-merge repo the PR title *is* the release type.** GitHub sets the
  squash commit subject from the PR title, and release-please reads only that
  subject — so a `chore:`/`docs:`-titled PR merges with **no release** even when it
  carries releasable content. The **release-content guard**
  (`release-content-guard.yml` → `scripts/require-release-title.sh`, unit-tested by
  `task test:release-title`) fails a PR that changes `ai/skills ai/agents templates scripts`
  under a non-releasing title, so consumers pinning a released tag actually receive
  the change. Retitle with `fix:`/`feat:` rather than bypass. Automated dependency
  PRs (Renovate/Dependabot) are skipped.
- Issue types map many-to-one onto these commit types. Personal-account repos
  use the equivalent work-type labels as that mapping's substrate because native
  issue Type is unavailable there; organization repos use native Type and no
  work-type label. See [project-management.md](project-management.md).
- **Milestones use an explicit naming mode**: a version milestone is named after
  its git tag (`v1.1.0`), while a rolling-release or tooling repo may use a
  finite scope-batch name when the version is not a planning input. See
  [project-management.md](project-management.md).
