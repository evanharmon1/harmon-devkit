#!/usr/bin/env bash
# advance-to-integration.sh — chain a converged confidence stage into
# integration entry with one resumable command (harmon-devkit#1920).
#
# Usage: advance-to-integration.sh --repo OWNER/REPO --slate ID --session ID
#   --run-id ID --title TEXT --body-file FILE [--repo-root DIR]
#   [--owner-token TOKEN] [--exit-engine FILE]
#   [--merge-base-policy FILE | --merge-base-policy-absent]
#   [--security-timeout-sec N]
#
# Run it in the lane's clean worktree (or name it with --repo-root) once the
# head is pushed to origin, which must be the repository --repo names. The
# owner token may come from RUN_RECORD_OWNER_TOKEN.
# Trusted copy: every asset this command loads resolves beside the copy that
# runs, so the copy that runs must itself be trusted — the owner's
# default-branch checkout, or a materialized merge-base copy — with
# --repo-root pointing at the lane worktree, per AGENTS.md § Rigor and
# Strategy.
# In order, each step skipped when the run record shows it already done:
#   1. capture the run's branch head and its active generation, and prove the
#      slate owns the run and the token owns the slate lock before anything is
#      run or written;
#   2. require a clean checkout of that head, then re-run the exit engine for
#      the confidence stage being left against it — review, challenge only when
#      review's recorded cap is 0, or verify when both caps are 0 — and require
#      action advance plus a last round that reviewed this exact head. Without
#      a merge-base flag the merge base's policy governs, derived by the
#      engine's lib/merge-base-policy.sh against origin's default branch;
#   3. transition to security, then run the run policy's pre_pr gate task in
#      the worktree under a timeout: only exit 0 passes, and the checkout must
#      still be that clean head afterwards;
#   4. adopt the branch's open same-repository draft PR at this head (a crash
#      after creation), or pre-flight `task guard:closing-keywords` on the title
#      and body, require origin's branch at this head, and `gh pr create
#      --draft`; then require headRefOid == head and isDraft == true;
#   5. resolve the next action, transition to integration, then bind-pr (the
#      run schema binds a PR only once integration is recorded; a rerun binds
#      the verified draft when a crash fell between the two).
# It posts no review request: the next action names
# integrate/assets/drive-codex-cycle.sh, in the order trigger-timing reports for
# the policy's review_trigger. A rerun after success re-confirms the bound draft
# at the head the security exit recorded and reports the same next action; a
# branch that moved since then needs judgment. Plan-level bindings and label
# mirroring stay with the orchestrator.
#
# Stdout is one stage-outcome.v1 document whenever the run, its generation and
# the head were established; diagnostics go to stderr.
#
# Exit codes:
#   0  integration entered; run drive-codex-cycle.sh, which waits for CI first
#   10 integration entered; run drive-codex-cycle.sh now (with-push order)
#   11 integration entered; no Codex cycle is owed (cap 0 or Codex not required)
#   2  indeterminate or refused: usage, run state, engine or record write
#   3  the security step blocked: a dirty or moved checkout, no pre_pr gate,
#      or a gate that failed, timed out, was killed or could not run
#   4  judgment needed: a confidence stage is still owed, no advance verdict
#      binds this head, or the head moved since the gates ran
#   5  the draft could not be published, adopted or verified
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec node "$asset_dir/advance-to-integration.mjs" "$@"
