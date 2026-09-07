# Guides

Calm, repeatable how-tos read *in advance* (the crisis counterpart is
[runbooks/](../runbooks/)).

- [onboarding.md](onboarding.md) — get a new dev or agent productive: setup,
  where things live, the dev loop. The human entry procedure.
- [deploying.md](deploying.md) — how to cut/promote a release (the calm
  procedure); cross-links a rollback runbook for when it goes wrong.
- [troubleshooting.md](troubleshooting.md) — symptom → cause → fix for **dev**
  problems (broken build, failing local setup). Distinct from runbooks, which
  cover prod incidents.
- [devflow.md](devflow.md) — the `rigor`/`strategy` execution-policy model
  behind `.devflow.toml`: what each axis means, how they resolve and
  conflict, role-tier overrides, budgets, reviewer selection, registry
  ownership boundaries, and the natural-language interface.
- [bot-account.md](bot-account.md) — the `evanharmon1-bot`
  machine account: how it gets repo access, how to mint and rotate its
  fine-grained PAT, and why the collaborator grant — not the token — is where
  per-repo granularity lives.
- [devcontainers.md](devcontainers.md) — the dual-profile devcontainer (bot vs
  dev), local secrets via **1Password Environments**, GHCR prebuilds, and
  **Coder** setup.
- [devcontainer-performance.md](devcontainer-performance.md) — tuning CPU/RAM
  for the devcontainer; the real levers live in Coder and WSL2, not this repo.
- [devcontainer-incidents.md](devcontainer-incidents.md) — worked diagnoses of
  real devcontainer failures (lifecycle chain aborts, Claude auth lost on
  rebuild, stale Coder volumes) and where the shipped fix for each lives.
- [codex-review.md](codex-review.md) — second-model review via the OpenAI
  Codex CLI: `task challenge` / `task review`, the automatic Claude → Codex
  stop-gate toggle, and where the finding-adjudication protocol lives.
- [worktrees.md](worktrees.md) — when a piece of work earns its own git
  worktree (the three-question rule: commits, repo tooling, durability) and
  the one sanctioned way to create and remove one (`task worktree:new` /
  `task worktree:rm`), including how it pairs with Herdr.
- [herdr.md](herdr.md) — using Herdr for real work: workspaces, tabs, panes,
  agents and sessions and how they relate; everyday workflows; worktrees;
  fanning out many worker sessions from one orchestrator (subagents vs pane
  workers, lifecycle, cleanup); and running several harnesses — Claude Code,
  Codex, Antigravity, OpenCode — side by side on their own subscriptions.

TODO: add more guides, e.g. "local development setup", "add a feature", "how X works".
