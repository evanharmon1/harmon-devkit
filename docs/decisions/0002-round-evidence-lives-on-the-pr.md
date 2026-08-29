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
- Evidence is public wherever the PR is. Finding text is free text and can
  quote a credential a reviewer found, so every evidence post is secret-scanned
  first and fails closed; the branch scan does not cover git-directory files.
- Anyone can post fenced JSON on a public PR, and an author can edit or delete
  a comment. The run record therefore stores each evidence comment's id,
  author, and payload digest, and the harvester accepts only comments it
  names, from the orchestrator's login or the repo's trusted actors, whose
  body still matches the digest — anything else is reported as tampered.
- "One comment per stage" is the normal case, not a limit: when a stage's
  rounds exceed GitHub's ~65 KB comment size, the comment is continued in
  order under the same marker sequence, and the stats script reassembles it.
- A run that ends without a PR posts its stage comments on the issue instead,
  beside the run record that lives there from kickoff.
