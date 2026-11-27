#!/usr/bin/env bash
# drive-handoff.sh — drive the owner half of an integrator pass, from the
# validated result to the rendered PR body, with one resumable command
# (harmon-devkit#1919).
#
# Usage: drive-handoff.sh --repo OWNER/REPO --pr N --slate ID --session ID
#   --run-id ID --result FILE --actor-id ID [--adjudication FILE]
#   [--codex-state FILE --codex-repo-dir DIR] [--sections LIST]
#   [--repo-root DIR] [--owner-token TOKEN] [--command-timeout-ms N]
#
# Run it in the lane's worktree (or name it with --repo-root). --result is the
# integrator's result file, unchanged. --actor-id is the GitHub account that
# posts the round's evidence. --sections defaults to deferred-findings. The
# owner token may come from RUN_RECORD_OWNER_TOKEN. Each command defaults to a
# 180000 ms timeout. --command-timeout-ms sets a positive integer in milliseconds.
# A timeout stops the command's process group. The driver forwards SIGINT,
# SIGTERM and SIGHUP to that group, then exits by the received signal with
# no outcome on stdout. An interrupt during publish can leave .publish-lock.
# The next run's concurrent-publish blocker explains the recovery. Confirm
# no publish is running, then remove the lock and retry.
# SIGKILL or another unforwarded signal can leave the command tree running
# (harmon-devkit#2144). A descendant that leaves the command's group is
# outside group cleanup.
# In order, each step skipped when this command's record and the live state
# show it already done:
#   1. capture the run's branch head and active generation, prove the slate
#      owns the run and the token owns the slate lock, and require integration
#      to be the active stage with this PR bound;
#   2. validate the result; require its head, the branch head and the live PR
#      head to be one commit on an open draft, so a result on a moved head is
#      answered by the head-moved stop whatever else it says; then take its
#      `payload.collection` as is, before anything is written. Only
#      `continue`, or a judgment request that names no pending predicate
#      (ci-pending, review-pending, read-failed), goes on to the receipt. A
#      pending, retry or stop result is answered by its own `next_action`, a
#      judgment request that names a pending predicate by what its collection
#      still owes (below), and nothing is retained; a result without the
#      record is refused. Only a complete collection can end in exit 0. No
#      evidence is collected again;
#   3. for a result not yet retained, require step 7's body conditions now,
#      so a stale result is never retained;
#   4. retain the result with `run-record.mjs receipt`, which validates the
#      whole run record first, so an invalid record (a hand-written settlement,
#      for one) is never published from;
#   5. record a supplied --adjudication with `run-record.mjs adjudicate`; with
#      findings and no adjudication, stop for the owner. This command never
#      writes an adjudication of its own, an empty one included;
#   6. for an adjudicated round with no evidence comment registered in
#      run.json, build the round's evidence from the retained pass and
#      adjudication, scan and redact the complete comment, and publish it
#      through review/assets/post-evidence.sh. A result whose collection is
#      incomplete stops here with what it still owes (below);
#   7. require the live review activity to be what the result's final
#      snapshot saw, or to differ from it only by this command's own publish
#      (below), and the PR body to carry no hand-written copy of a section
#      being published outside the managed markers; then run
#      `render-dev-flow.sh publish` and check the head, the body and the
#      activity it left. Every read of the activity surfaces checks the PR
#      head too, so a push landing after the publish's own last head check is
#      a moved head.
#
# Judgment. A judgment is requested only for a result this command has
# retained and whose findings have no recorded adjudication, whatever its
# verdict: a clean result can carry findings whose dispositions were applied.
# It never asks for a decision it could not record (a result the receipt
# cannot admit) or one the record already holds. In both cases the answer is
# what the collection still owes, by the rule the integrator applies to a
# result with no findings: wait on the named predicates, retry when only
# review activity moved, or stop on a moved head or a spent retry.
#
# Review activity is the readiness gate's five-surface fingerprint, computed
# here with the gate's own projections. After `render-dev-flow.sh publish`
# returns, the surfaces are read again and three things must hold, whether or
# not the publish changed the body: the body is the one the publish reports,
# the text outside the managed sections is what was read before the publish,
# and the activity equals the pre-publish read with that body. A read that
# differs holds someone else's activity: the handoff stops (exit 14) and the
# published body is withdrawn from this command's record.
#
# Recorded effects. This command records each external effect in
# <record>/drive-handoff.json the moment it is confirmed and before any
# further read: the retained receipt, the recorded adjudication, the evidence
# comment id as run.json registers it, what it read apart from the managed
# sections before the edit (the title, the non-body fingerprint lines and the
# body text outside the managed sections), the publish_id saved before the
# edit and cleared when the driver records the successful publish, and the
# published body digest as `render-dev-flow.sh publish` reports it. A restart
# adopts an effect exactly when the live state matches that record:
#   - the receipt, the adjudication and the evidence registration are checked
#     against the run record; the comment on GitHub is not read again. One
#     that the run record no longer shows stops the handoff (exit 2);
#   - the PR body is checked on GitHub. Its SHA-256 must match the digest the
#     driver recorded, the renderer reserved, or the renderer verified and
#     recorded before clearing that reservation. A renderer reservation and
#     completion must match the repository, PR, expected live head and
#     sections. A reserved digest is eligible if the reservation is legacy
#     (it has neither the run nor reservation ID) or carries this run and
#     the recorded publish_id. A completion requires both IDs to match.
#     The recorded title, non-body review activity and text outside managed
#     sections must also match. A changed body without matching proof takes
#     the stale stop (exit 14) before any new edit.
#
# The writer admits a later result only once the earlier round has its
# adjudication document, so a clean round followed by another pass first
# needs the owner's (empty) adjudication, recorded by re-running with
# --adjudication.
#
# Stdout is one stage-outcome.v1 document whenever the run, its generation and
# the head were established and the driver was not interrupted. Diagnostics go
# to stderr. The outcome's evidence names the retained pass, the integrator-pass
# ordinal and each review cycle from their own fields, and for a judgment stop
# every finding id.
#
# Exit codes:
#   0  handoff rendered: receipt, adjudication, evidence and PR body are current
#   2  indeterminate or refused: usage, run state, or a failed step or read
#   10 judgment needed: the retained result's findings have no recorded
#      adjudication
#   11 waiting: the result, or what its collection still owes, names a
#      predicate that is still pending
#   12 retry: the result, or what its collection still owes, asks for the one
#      bounded collection retry. A command timeout uses the driver's own retry
#      key (drive-handoff.sh:12) and names the command and any stale lock recovery.
#      A timeout before the run binds exits 12 with stderr and no stdout.
#   13 the result is not a handoff: blocked, a stop, no collection record, a
#      duplicate wakeup that retained no pass, or an adjudicated collection
#      that owes a stop
#   14 stale: the head or the review activity moved since the final snapshot
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec node "$asset_dir/drive-handoff.mjs" "$@"
