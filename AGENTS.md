# AGENTS.md

Guidance for AI coding agents (Claude Code, Gemini CLI, GitHub Copilot, Codex,
...) working in Harmon DevKit. `CLAUDE.md`, `GEMINI.md`, and
`.github/copilot-instructions.md` are symlinks to this file — edit only
`AGENTS.md`.

## Project Overview

Harmon DevKit — my personal developer kit of reusable templates and boilerplates
(Docker Compose, Ansible, shell scripts, serverless functions, and more),
standalone scripts, and AI assets (skills, prompts, agents). This is **not** a
monorepo and has no application code of its own — it is a flat collection of
independent, copy-paste assets organized by category under `templates/`,
`scripts/`, and `ai/`.

Repo: https://github.com/evanharmon1/harmon-devkit — see [docs/README.md](docs/README.md) for the
documentation map, [docs/architecture/README.md](docs/architecture/README.md)
for the architecture, and [DESIGN.md](DESIGN.md) for design/UX intent.

## harmon-platform

One of five repos in **harmon-platform** (Evan's developer & DevOps platform + homelab):
[harmon-init](https://github.com/evanharmon1/harmon-init) (the Copier repo template),
[**harmon-devkit**](https://github.com/evanharmon1/harmon-devkit) (this repo — boilerplates/scripts/AI assets),
[harmon-dotfiles](https://github.com/evanharmon1/harmon-dotfiles) (chezmoi dotfiles),
[harmon-ops](https://github.com/evanharmon1/harmon-ops) (machine setup),
[harmon-infra](https://github.com/harmonops/harmon-infra) (homelab IaC). See the README for the full table.

## Repository Layout

- `templates/` — copy-paste boilerplates by category: `ansible.md`, `docker/`
  (genericStack, n8n-compose), `scriptTemplates/` (Go, Python, Shell),
  `serverlessFunctionTemplates/` (AWS Lambda, GCP, Netlify), `webTemplates/`.
  Each category has a README; the root README has the full template index.
- `scripts/` — standalone scripts and utilities: `appleScripts/`
  (AppleScript/Automator apps), plus the harmon-init helper scripts
  (`status.sh`, `lint-hygiene.sh`, `test-*.sh`, …) that back the Taskfile.
- `ai/` — AI assets by type: `skills/`, `agents/`, `prompts/`, `rules/`,
  `evals/`, `tools/`, `workflows/`, `mcp/`, `knowledge/`, `memories/`. `skills/`
  is the populated one (Agent Skills convention — a `SKILL.md` with
  `name`/`description` frontmatter); the standouts are `repo/standardize-repo`
  (applies harmon-init's conventions to a repo), the `design/` suite, and the
  `universal/` dev-workflow session suite (`/orient`, `/preflight`,
  `/implement`, `/shepherd`, `/retro`, `/close`). `agents/` holds shared
  subagents — one flat `<name>.md` each, thin by design and deferring to the
  skills above; see [ai/agents/README.md](ai/agents/README.md) for the layout
  and the portability contract.
- `snippets/` — small reusable code snippets (placeholder).
- `docs/` — project docs (see [docs/README.md](docs/README.md)); the
  new-project [checklist](docs/CHECKLIST.md) lives here.

## Hard Rules

Non-negotiable, regardless of any autonomy granted elsewhere in this file:

- **Never write to a password manager or credential store unprompted.** Do not
  create, modify, archive, or delete anything in 1Password (items, fields,
  vaults — via the `op` CLI or any other means), OS keychains, or any other
  secret store unless the user explicitly requested that specific write in the
  current conversation. Even when asked, restate exactly what will be written
  and get confirmation before executing — announcing intent and proceeding in
  the same turn is not consent. Read operations (`op read`, `op item list`,
  `op inject` over existing references) are fine.
- **Never reference harmon-dotfiles in shipped output.** harmon-init,
  harmon-devkit, and harmon-infra are independent of the personal dotfiles
  repo: nothing they ship may name it, hardcode a path into somebody's
  dotfiles checkout (`~/.dotfiles/…` leaks the same setup without naming the
  repo), or require dotfiles to be installed, present, or accommodated. A
  consumer cannot read that repo, so rationale belongs here rather than cited
  offsite, and content this repo owns is never described as kept "in sync"
  with it. The permitted coupling is one-way and optional: harmon-dotfiles may
  pull from these repos at a pinned tag; they never point back. Shipped output
  here is `ai/`, `templates/`, `scripts/`, and `snippets/` — the vendored
  skills and agents reach every repo harmon-init generates. Root-only mentions
  ship to nobody and create no dependency (the sibling-repo lists, the
  "related repos" tables, `.claude/settings.json` grants,
  `.devcontainer/related-repos.txt`), which is why `validate:independence`, the
  guard that enforces this (unit-tested by `test:independence`), scans those
  four directories and not the whole
  repo. The enforcement pair — that guard and its unit test — is the only
  carve-out: enforcement has to spell out the string it forbids, exactly as
  this rule's prose does, and a test that cannot write a violation cannot prove
  the guard catches one. The rule text is out of scope because it sits at the
  root, those two files are out of scope by name, and nothing else under the
  four trees is exempt. **chezmoi as a technique is not covered**: `standardize-repo` carries
  real chezmoi guidance because one of the repos it may be pointed at *is* a
  chezmoi source. What must never ship is the personal repo's name and
  rationale that exists only there — not the technique.

## Commands

All commands go through the Taskfile (single source of truth — CI, git hooks,
and humans run the same targets):

```bash
task check       # FAST gate (<~1 min) — run constantly; safe for hooks/agents
task verify      # definition-of-done gate — check + validate + test; run before finishing
task ci          # FULL CI mirror — run before/instead of opening a PR
task fix         # auto-format then lint
task test        # tests
task security    # Semgrep CE + gitleaks + dependency audit
task challenge   # adversarial Codex second-model review — advisory, not in verify/ci
task review      # Codex verification checkpoint before task ci
```

`check` is deliberately kept fast (lint) so editors, git hooks, and
AI agents can run it on every change without getting bogged down. `verify` is
the definition-of-done gate — check + validate + test plus the quick
Taskfile/hook guards (the Foreman v2 vocabulary: verify = check + build +
test). `ci` mirrors the CI pipeline locally (`verify`, `security`, the devcontainer permission assert) — so you can
reproduce a CI run on demand instead of waiting on a PR. Keep it that way: a
check the build workflow **gates on** and that can run locally belongs in `ci`
too, or the "mirror" quietly stops being one. The one carve-out: a check that
needs **CI-only infrastructure** (a browser install, a service container,
credentials that only exist on a runner) stays out of `ci` and is documented as
an exception here rather than being faked locally.

## Dev Loop

Bias toward shipping: drive every change to an open PR instead of stopping at
a green local diff. Work in small, PR-sized units, and move to the next stage
on your own — an open PR with green checks is the default deliverable, not
something to ask permission for.

- **Branch** — feature branch off `main`; never commit directly to `main`.
- **Edit + `task check`** — the fast inner loop; run it constantly and fix
  lint immediately.
- **`task verify`** — when the change feels done, loop edit → verify until
  green; verify is the definition-of-done gate.
- **`task challenge`** — adversarial second-model review. Adjudicate per
  "Second-Model Review" below, fix confirmed findings, re-run `task verify`,
  then **re-run `task challenge`**. The stage passes only when a re-run comes
  back with **no confirmed P0 or P1 findings** — fixing the findings is not
  the exit condition, a clean pass is. **P2s do not gate this stage**: carry
  them to the PR (see "Deferring P2s" below). This loop is
  **self-referential** — the fixes you make in response to a round become the
  next round's input, so it can generate its own work indefinitely — and that
  is what the cap defends against: max **4** challenge → fix → re-challenge
  rounds; if P0/P1 findings persist, stop and escalate to the maintainer.
  "Between rounds, check what the findings are about" below is how you catch
  the loop feeding on itself before the cap does.
  A `task challenge` round is long — 5–15 minutes is ordinary, past most
  agents' tool-call timeouts — so **run it in the background and poll**
  instead of blocking one call on it. Growing output means running, not hung;
  relaunching a live run only doubles the cost. Re-challenge with a bare
  `task challenge` — it covers the branch's commits *and* the working tree,
  so an uncommitted fix cannot narrow the re-run to itself; an explicit
  `--base`/`--uncommitted` reviews one half only. Committing each round's
  fixes first is still tidier, not load-bearing. Details:
  [docs/guides/codex-review.md](docs/guides/codex-review.md) ("Duration and
  backgrounding").
- **`task review`** — verification-checkpoint review; same adjudication, same
  P0/P1 clean-pass exit condition, the same self-referential shape and so the
  same reason for a cap, and the same background-and-poll handling, with its
  own max **4** rounds.
- **`task ci`** — the full CI mirror; fix anything it catches.
- **Open the draft PR** — conventional commit, push the branch, `gh pr create
  --draft` with a clear what/why/verification summary. Draft is the agent
  workbench: implementation and automated review are still active.
- **Git transport** — pushes authenticate over HTTPS via `gh` (provisioned
  hosts and the devcontainers rewrite GitHub SSH URLs to HTTPS via
  `url.insteadOf`, so that git never needs an SSH agent: a headless container
  has none, forwarding one into an interactive container is lockout-prone, and
  `gh` already holds an HTTPS credential that works for both).
  Never work around an SSH failure
  by pushing to a raw `https://…` URL — a URL push bypasses the named remote
  and leaves stale tracking refs. On an unprovisioned host, force the helper
  and the rewrite against the *named* remote:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' -c url."https://github.com/".insteadOf="git@github.com:" -c url."https://github.com/".insteadOf="ssh://git@github.com/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com:443/" -c url."https://github.com/".insteadOf="ssh://git@ssh.github.com/" push`
  (a credential helper only applies to HTTPS, and `insteadOf` is prefix
  matching — every SSH form needs its own mapping, hence all four).
- **Shepherd the draft (`/shepherd`, max 4 rounds).** `gh pr create --draft`
  returning is
  the trigger for this stage, not the end of the work — enter it deliberately
  instead of judging for yourself when the PR is finished. `/shepherd` is the
  procedure, and like the rest of the session suite it is **user-invocable
  only** (`disable-model-invocation: true`), so an agent enters the stage by
  reading `.claude/skills/shepherd/SKILL.md` and following it — not by calling
  a slash command it cannot call. Start by re-reading any **unsettled**
  findings the PR description defers to this stage — they are open work, not a
  changelog; mark each one off in the body as you settle it. Then watch CI
  (`gh pr checks <n> --watch`) and incoming bot/human reviews. When a check
  fails or a review lands findings, treat the findings as hypotheses: verify
  them against the code, fix only what's confirmed, explain rejections in a PR
  comment, push the fix commit, and watch again. **This is where
  lower-priority findings are settled** — those the PR description defers here
  plus anything the PR reviewers raise: fix, decline with reasoning, or file as
  a follow-up issue, but do not leave them unaddressed. Shepherd-round fixes
  must pass `task ci` (the full local CI mirror — it gates the same stages the
  remote pipeline judges) before each push; the local challenge/review loops
  are not re-entered — the post-push cloud/bot review is the second-model
  check at this stage. When Codex cloud review is enabled, every pushed head
  needs its own terminal authenticated result: an exact-head review or inline
  finding, a top-level result naming an unambiguous prefix of that head, or a
  👍 on the exact `@codex review` trigger comment reserved for that head.
  Stale verdicts never transfer across pushes. Trigger at most twice per head,
  waiting 10–15 minutes after checks settle for each attempt. Do not reserve or
  post an attempt before every required check has settled. After the second
  unavailable attempt, or immediately on an indeterminate condition that needs
  reconciliation, stop and escalate rather than falling back to CI alone.
  Persist the head, attempt, and exact trigger-comment ID so
  a resumed session cannot duplicate a request. This cap is independent of
  the other loop caps. Codex Automatic reviews must be disabled as a
  human-configured external prerequisite: draft-time `@codex review` cycles
  are the authoritative signal, and `gh pr ready` must not launch a new
  asynchronous review after the readiness gate. **Only one active shepherd may
  own a PR at a time.**
  The persisted state prevents duplicate requests across interrupted or resumed
  sessions in the same checkout; it is not a distributed lock across separate
  checkouts or machines. Do not shepherd the same PR concurrently elsewhere.
  If ownership is ambiguous, stop and reconcile the remote trigger history
  before continuing. If checks still fail or findings remain after 4 rounds,
  leave the PR draft, stop, and summarize what's unresolved on the PR for the
  maintainer. Once the complete readiness gate is clean for the unchanged
  current head, confirm that every required workflow and review app can run on
  drafts (or was explicitly dispatched and settled on that head). Automation
  available only through `pull_request.ready_for_review` is a configuration
  blocker, because promotion can notify CODEOWNERS before its result exists.
  Then run `gh pr ready`, confirm the PR is no longer draft and the head did
  not change, and hand it to the human reviewer. Treat promotion as a
  reconciled transition: fingerprint the PR body, reviews, top-level and inline
  comments, and thread resolution immediately before and after promotion. Any
  content change invalidates the gate. Even when the command or confirmation
  fails, bounded-fetch the remote state; if the open PR is ready on any
  unverified head or content snapshot, return it to draft and confirm that
  state before resuming or stopping. Where the
  vendored `/shepherd` skill states a different cap or exit condition, **this
  file wins** — vendored skills are synced on their own release cadence and
  can lag a policy change made here.
- **Checks green is a non-terminal state.** Reporting "all checks pass"
  without having polled reviews and inline comments is not a handoff — it is
  the middle of the shepherd stage. Bot and human reviews land *after* checks
  settle, so `gh pr checks --watch` returns at exactly the moment the review
  has not run yet: an empty comment list read at that instant means "not
  reviewed yet", not "nothing to answer". Wait for **both** signals before
  judging the PR done. `/shepherd` step 2 bounds the wait and defines the
  current-head classifier. If Codex cloud review is enabled, absence of a
  terminal current-head result after its two bounded attempts is an
  escalation, never permission to proceed on CI alone.
- **Stop at ready for review.** Once checks pass and no review findings are
  unresolved, confirm all required automation settled while the PR was draft,
  promote the unchanged draft with `gh pr ready`, report the human handoff, and
  stop. A failed or indeterminate gate stays draft; reconcile a partial
  promotion and return any open unverified PR to draft. Merging is always a
  human decision.

## Definition of Done

- `task verify` passes.
- Conventional commit message (types: build, chore, ci, docs, feat, fix, perf,
  refactor, revert, style, test).
- Never bypass git hooks (`--no-verify` is forbidden); fix the underlying issue.
- Work on a feature branch; direct commits to `main` are blocked.
- **Never merge to main yourself** — no `gh pr merge`, `git merge`, or push to
  `main` without the maintainer's explicit, per-merge approval, even when CI is
  green and the ruleset would allow it. Open the PR and shepherd it — checks
  green with reviews unpolled is not the stopping point — promote the clean
  unchanged draft to ready for review, then report and stop; merging is always
  a human decision.
- **Reply to every inline PR review comment in its own thread** — bot
  reviewers and humans alike. Treat findings as
  hypotheses: verify each against the code, fix what's confirmed, and post the
  rejection reasoning with evidence otherwise. Post replies with
  `gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment-id>/replies -f body=…`
  (comment IDs from `gh api …/pulls/<n>/comments`). A rollup summary comment
  on the PR is optional in addition, never a substitute for per-thread
  replies.
- Releases are intentional: release-please keeps a rolling release PR from
  conventional commits; merging it cuts the tag/release. Nothing bumps on a
  normal merge. `task release:*` remains as a manual override.
- **A PR that changes `ai/skills ai/agents templates scripts` must use a
  `fix:`/`feat:` (or breaking) PR title.** Squash-merge feeds the PR title to release-please,
  which tags only feat/fix/breaking — so a `chore:`/`docs:` title over these
  paths would merge without cutting a release, and consumers pinning a released
  tag would never receive the change. The `release-content-guard.yml` check
  enforces this; retitle rather than bypass. Other changes keep their normal type.
  Pre-flight it locally with your intended title:
  `PR_TITLE="<title>" BASE_SHA=main task guard:release-title`.

## Second-Model Review (Codex)

A second AI model (the OpenAI Codex CLI) reviews changes on demand. Local and
advisory only: nothing runs in CI, and no `verify`/`ci` step depends on Codex.
Setup and mechanics: [docs/guides/codex-review.md](docs/guides/codex-review.md).

- `task challenge` (→ `challenge:codex`) — adversarial review: challenges the
  architecture and approach; hunts authorization bypasses, data-loss paths,
  unsafe rollback, races, hidden coupling, operational failure modes, and
  needless complexity. Steer it with e.g.
  `task challenge -- --base main focus on the migration path`.
- `task review` (→ `review:codex`) — verification checkpoint: double-checks
  the implementation, consistency, and test coverage before `task ci`.
- `task codex:gate:enable` / `:disable` / `:status` — the automatic
  Claude Code → Codex stop-gate (the codex plugin's Stop hook reviews each
  editing turn and blocks completion on material findings). Per-repo,
  per-machine state; defaults off. Inside Claude Code the equivalents are
  `/codex:review`, `/codex:adversarial-review`, and `/codex:setup`. The
  toggles are approval-gated (`permissions.ask`), `disable` refuses
  non-interactive shells, and agents must **never disable the gate to get
  past a BLOCK** — adjudicate the finding or escalate to the maintainer instead.

These tasks slot into the **Dev Loop** above: after `task verify` goes green,
before `task ci`. If Codex cloud review is enabled for the repo, shepherding
also requires a terminal result attributable to the current PR head. The
canonical `/shepherd` skill owns the exact classifier and persistent
two-attempt procedure; PR-level or stale reactions do not satisfy it.

**Treat Codex findings as hypotheses, not authority.** For every finding:

1. Verify it against the actual implementation, surrounding code,
   requirements, and tests.
2. Classify it: confirmed, plausible but unproven, or false positive.
3. Fix only confirmed findings; add or improve regression tests where
   appropriate.
4. Explain why any rejected finding is incorrect or irrelevant.
5. Re-run `task verify` (and the other relevant gates) after fixes.
6. Finish with a concise adjudication table: finding → priority →
   classification → evidence → action taken.

**Between rounds, check what the findings are about.** Those six steps are all
*per-finding*, so a reviewer can be right every round while the loop as a whole
diverges: each fix adds surface, the next round attacks that surface, and the
findings stay individually defensible right up to the cap. Before starting a
round's fixes, ask where they *live* — in the change you set out to make, or in
code that exists only because an earlier round asked for it. **A round whose
findings are all about the previous round's fix is the tell**, and it is
visible in round 2 — the first round that can show it. Do not wait for the
pattern to be unmistakable in round 3, by which point only one round is left.

**Deleting the added code is a legitimate way to reach a clean pass.** When a
round's findings are about scaffolding rather than the change, weigh removing
that scaffolding against hardening it once more — a remediation can be correct
in the abstract and wrong for the artifact. A documentation guide that has
grown a hand-rolled process supervisor earns real, defensible P1s about per-run
state, process-group supervision, and PID reuse; every one of them becomes moot
when the recipe is deleted instead of hardened. That is not giving up on the
findings: the stage exits on a **clean re-run**, and a re-run does not care
whether a finding was answered or made inapplicable. Name the mooted findings
in the adjudication table *and* in the message of the commit that removes the
code — the table is scrollback, but the commit is why the code is gone, and it
is the record a later round or a different session can still find.

One endpoint is worth knowing: if the deletion empties the change *entirely*,
there is no clean pass to reach — `codex-review.sh` refuses an empty scope
non-zero by design, so the stage cannot pass and re-running will not change
that. Treat it as the answer rather than a failure to work around: a change
that has become empty is abandoned, not reviewed clean.

**Severity gating.** Both tasks ask Codex to label every finding `P0`
(breaks correctness, security, or data integrity in ordinary use, or breaks
an existing contract), `P1` (a real defect or materially wrong design
decision with a plausible trigger), or `P2` (worth knowing, not
merge-blocking: hardening, unlikely edge cases, maintainability, non-critical
test gaps). The scale is defined in `scripts/codex-review.sh`, not inherited
from the Codex CLI's own labels, so the gate keeps its meaning if Codex
changes its output. **Only P0 and P1 gate the local loops.** Adjudicate P2s
too — never suppress or ignore one — but carry them to the PR-shepherd stage
rather than spending a local round on them. A P2 you judge worth fixing
immediately may of course be fixed in place; it just does not hold the stage
open.

**Deferring P2s.** The handoff is the **PR description**: list every deferred
P2 under a `## Deferred findings` heading as an unchecked task-list item —
`- [ ] <file:line> — <finding>` — with enough detail to adjudicate it later.
This is not bookkeeping: `task challenge` and `task review` run locally and
their output is ephemeral, and the cloud reviewer reposts only high-priority
findings, so a P2 that is not written into the PR body is simply lost.

Record each one **the moment you defer it**. Challenge and review both run
before `gh pr create`, so there is usually no PR body to write to yet: append
it to the file
`git rev-parse --git-path "deferred-findings/$(git branch --show-current)"`
names (`mkdir -p` its directory first) — but only if that finding is not
already listed. A stage exits on a *clean re-run*,
so an unchanged P2 is reported again by design, in every remaining round and
again by the next stage; appending blindly would hand the shepherd four copies
of one finding to settle. Match on location plus substance, not exact
wording — the same finding rarely comes back phrased identically. Then
move the list into the description when you open the PR (then delete the
file). Terminal scrollback is not a record — a context reset between
`task challenge` and `gh pr create` would take the findings with it.

**Sweep for orphans when you open the PR.** List the whole tree —
`ls -R "$(git rev-parse --git-path deferred-findings)"` — and account for
every file it holds, not just your branch's. Renaming a branch (`git branch
-m`) or deleting one strands its notes under the old name, where nothing will
ever look for them again; a rename mid-change is exactly when that happens.
Adopt an orphan into this PR if it belongs to this work, otherwise leave it
and say it is there. Listing costs one command; migration logic would cost a
mechanism that then needs its own correctness argument.

That path is not arbitrary. It sits in the **git directory**, so it is
deterministic (any later session in this checkout finds it the same way, and
`git rev-parse` resolves it correctly inside a linked worktree) and invisible
to `git status`. It is keyed by **branch** because an ordinary clone switches
branches in place: with one shared file, opening branch B's PR would sweep up
branch A's findings and then delete A's only copy of them. The branch name
becomes a *path*, verbatim and without a suffix — folding `/` to `-` would
collide `feat/x` with `feat-x` and reintroduce exactly that loss, and adding
an extension would make `foo` (a file) block `foo.md/bar` (needing a
directory). Used as-is, the mapping is git's own ref namespace, and git
already forbids one live branch from being a path prefix of another. A note in the *worktree* would be worse than none:
`codex-review.sh` puts uncommitted files in scope whenever the tree is dirty,
so the note would be handed to the next bare `task challenge` as part of the
change under review — a file of open findings, presented to the reviewer as
work to adjudicate.

The shepherd stage settles every entry and **edits the PR body to tick it**
(`- [x] … — fixed in <sha>` / `declined: <reason>` / `filed as #<n>`) in the
same round. The checkbox is the resolution state: an entry left unchecked is
open work, so a later round — or a different session — can tell at a glance
what it still owes without re-adjudicating what is done. That obligation is
stated here and in the Dev Loop above, and holds whether or not the optional
`/shepherd` skill is installed to automate it.

**Loop cap and exit:** a stage exits only on a **clean re-run** — no
confirmed P0 or P1 findings — never on "findings fixed" alone, with at most
**4** challenge iterations and **4** review iterations (challenge → fix →
re-challenge, and likewise for review). If P0/P1 disagreement persists at the
cap, stop and surface it to the maintainer instead of iterating further.

One caveat on the automatic stop-gate: the codex plugin's Stop hook applies
its **own** notion of a material finding and may BLOCK on something you have
classified P2. Adjudicate it (fix it, or state the reasoning) — **never**
disable the gate to get past a BLOCK.

## Conventions

Full reference: [docs/conventions.md](docs/conventions.md). Highlights:

- Conventional Commits; `group:action` Taskfile naming (e.g. `lint:shell`, not
  `shell:lint`); pin actions by SHA + `# vX.Y.Z`.
- Git hooks are managed by lefthook (`lefthook.yml`) and delegate to Taskfile
  targets — don't duplicate logic in hooks or workflows.
- Keep Taskfile `cmds:` trivial — inline strings aren't linted (`lint:shell`
  only covers `scripts/*.sh`). Put any pipeline/conditional/loop/`curl | bash`
  in a `scripts/*.sh` the task calls. `task test:tasks` checks the Taskfile
  compiles and setup tasks are safe no-ops.
- Indentation: 2 spaces default, 4 for Python/Terraform/Shell (`.editorconfig`).
- Secrets never go in git; local env via 1Password (`op run` / `op inject`).
- When generating or rotating secrets, keep secret values on stdin and use the
  destination-only helpers:
  `task secret:set:1p VAULT=... ITEM=... FIELD=... [SECTION=...]` for existing
  1Password fields and `task secret:set:gh NAME=... REPO=owner/repo` for GitHub
  repo secrets. Never pass secret values as command arguments, `--body` values,
  exported env vars, or Taskfile vars. The hard rule above still applies:
  agents must not run `secret:set:1p` or otherwise write to a password manager
  without explicit user confirmation for that exact write.
