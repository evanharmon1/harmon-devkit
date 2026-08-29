# 2. Round evidence lives on the PR

Date: 2026-08-29

## Status

Accepted

## Context

Dev flow v2 ([specs/dev-flow-v2.md](../../specs/dev-flow-v2.md)) computes
round exits from JSON evidence and tunes its convergence policy by replaying
real trajectories. v1 kept its ledger and deferred-findings sidecar as text in
the git directory and deleted them when the PR opened, so the only trajectory
that exists today was reconstructed by hand from a PR body. Evidence that is
deleted, or that lives only in one clone, cannot calibrate anything and cannot
be read by a retro.

## Decision

Round JSONs, the adjudication record, and the run record are kept in the git
directory while a branch is worked, and when the draft PR opens they are
**posted to the PR as one comment per confidence stage** in a fenced JSON
block, with the run record updated on every later transition. Nothing is
deleted at PR open. The PR is the durable home; the git directory is a working
copy.

## Alternatives rejected

- **Keep them only in the git directory.** Lost with the branch, invisible to
  the PR, and unreachable from another machine or a retro run later.
- **Commit them to the branch.** Visible and durable, but every round would
  add a commit that is not the change, pollute the diff the round gate
  classifies, and land in `main` on merge.
- **A separate orphan branch or gist.** Durable but detached from the PR that
  explains it, and a second thing to authenticate and garbage-collect.
- **Only the rendered tables in the PR body.** Human-readable but lossy —
  exactly what made omator#397's ledger a reconstruction rather than data —
  and the body is size-limited and edited by hand.

## Consequences

- `gh api` can harvest every trajectory in a repository, which is what
  `dev-flow-stats.sh` and the retro skill read.
- Evidence is public wherever the PR is; the round JSON must never carry
  secrets or full file contents, only paths, lines, and finding text.
- Comment size is bounded (~65 KB); a stage whose rounds exceed it is split
  across comments in order, which the stats script must reassemble.
