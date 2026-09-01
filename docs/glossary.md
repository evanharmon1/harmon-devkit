# Glossary

Term → one-line definition for the cross-cutting vocabulary of Harmon DevKit.
This is the **dictionary projection** of [the domain model](product/domain.md): it
points at the model for the real relationships and reasoning — it never restates
them. A flat lookup: scan for a term, don't read top-to-bottom.

Terms below are part of the harmon-init toolchain this repo is built on; add
project-specific (domain) terms as the model firms up.

| Term | Meaning |
|---|---|
| `verify` | The aggregate CI job in `build.yml` that rolls up the other jobs into one required status check (the merge gate). See [architecture/ci-cd.md](architecture/ci-cd.md). |
| `security` (check) | The required CI job running gitleaks + dependency audit, plus Semgrep CE when this job owns the SAST route. |
| `task` / Taskfile | go-task is the single source of truth for commands; lefthook hooks and CI both delegate to `task` targets so local and CI runs are identical. |
| release-please | Bot that maintains a rolling "release" PR from Conventional Commits; merging it cuts the tag, GitHub release, and CHANGELOG. Releases are intentional, never automatic on merge. |
| `evanharmon1-ci` (GitHub App) | The CI automation app that mints short-lived tokens for CI workflows (not a PAT). See [architecture/security.md](architecture/security.md). |
| bot profile / dev profile | The two devcontainer profiles: `bot` (`.devcontainer/`, AI agents, no Tailscale) and `dev` (`.devcontainer/dev/`, human, with Tailscale). See [guides/devcontainers.md](guides/devcontainers.md). |
| 1Password Environments | How devcontainer/local secrets are supplied — a virtual `.env` mounted over a pipe, never written to disk or git. |
| bot vs operator | Two identities: the AI **bot** account (scoped, can't merge `main`) and the human **operator** (full access). See [architecture/security.md](architecture/security.md). |
| orchestrator | The session that runs the dev flow — an interactive Claude Code session or a Foreman-dispatched headless agent, same procedure either way. Owns dispositions, promotion, and the only permitted override of a computed exit (upward: more rounds, never fewer), recorded with a reason. |
| role | A named job an agent performs in the dev flow (`implementer`, `challenger`, `reviewer`, `integrator`), declared in `agent-registry.json`. A role is the contract an agent fills — its result schema and the external writes it may make; an agent file is one implementation of a role. A role's brief is free-form; its result is schema-bound. |
| result / envelope | The schema-validated JSON an agent returns to the orchestrator: a common envelope (`schema`, `role`, `status`, `head`, `produced_at`, `producer`, `run`) plus a per-role payload. |
| run | One execution of the dev flow for an issue, from kickoff until ready-for-review or until it ends earlier (capped, abandoned, escalated); identified by `run_id` and `initiated_by` (`human` or `foreman`). Its run record lives on the issue from kickoff and carries the `interventions[]` the success metric counts. An issue may have several runs; a retry is a new run. |
| intervention | A human action between kickoff and `gh pr ready` other than answering an implementer's `blocked_question` (counted separately as "asked"). Post-ready human fixes are a gate failure, tracked as a second number. |
| finding | One challenger or reviewer observation on one head: `class`, `provenance`, `fingerprint`, producer priority, and a recommended `disposition`. Immutable once returned. Both roles share this core even though their evidence contracts differ. |
| adjudication record | The orchestrator's overlay on a round's findings, keyed by finding id: adjudicated priority and final disposition. The exit script reads this view, never the raw challenger/reviewer output. |
| round | The aggregate of the configured finder passes from one confidence role (`challenger` for challenge, `reviewer` for review) at one `reviewed_head`; the unit exit is computed over. |
| exit outcome | What the exit script computes from the adjudicated rounds: `continue`, `converged`, `diverging`, or `capped`. `converged` cannot fire before the policy's `min_rounds`; `capped` with adjudicated P0/P1 remaining escalates to a human (counted as an intervention) rather than opening the PR. |
| provenance | Whether a finding is about the original change (`original`) or about an earlier round's fix (`round:N`). Asserted by its challenger or reviewer, verified by the exit script against the diff. |
| finder | An external review product that produces findings (`codex-cli`, `codex-cloud`, `coderabbit`, `copilot`), declared in the registry with its GitHub actor id and stage affinity. |
| gate | The Taskfile target a push or PR-open must pass, resolved from `.devflow.toml` `[gates]`. The shipped defaults are `round_docs = "check"` for a docs-only diff and `round_code = "verify"` otherwise; consumers run the resolved target rather than hardcoding either command. Secret scanning is unconditional. |
| stage | One named phase of the dev flow lifecycle (kickoff … wrap; the full table is in [product/domain.md](product/domain.md) § Lifecycles). The orchestrator-driven span is implement → verify → challenge → review → security → integration. |
| check vs. confidence stage | `verify` and `security` are **checks**: deterministic, authoritative, gating. `challenge` and `review` are **confidence** stages: a second model poking at the change; they raise confidence and produce findings to adjudicate, but are never a determinative test. |
| gauntlet | Retired name for the challenge + review stages together. Do not use in new text. |
| orchestrator skill | `/orchestrator`: the standing operating mode of the originating session — its preferred tools and practices for dispatching roles (worktrees, dev environments, Herdr panes, subagents), validating results, adjudicating, and acting on computed exits. Loaded once and kept for the session; not a stage and never dispatched to an agent. |
| challenger | The role that works the challenge stage: returns attack scenarios, design-level findings, and de-scaffolding recommendations in `result.challenger`. It writes nothing outside its result and never fixes, disposes, or decides an exit. |
| integrator | The role (and agent) that works the integration stage (skill: `/integrate`): polls CI and reviewers, posts given text, returns evidence JSON. Never disposes findings or promotes the PR — the orchestrator does. |
| integration cap | (`integration` in the resolved `.devflow.toml` `[rounds.*]` policy; formerly `shepherd`.) Bounds Codex re-review cycles only. Answering every human and CI finding is unconditional — never skipped — but the fix pushes it takes are bounded by the policy's `remediation` cap, whose terminal action is escalation with the findings listed. `integration = 0` means "no Codex cycle required", never "abandon reviews". |
