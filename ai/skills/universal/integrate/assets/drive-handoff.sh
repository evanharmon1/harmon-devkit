#!/usr/bin/env bash
# drive-handoff.sh — drive the owner half of an integrator pass, from the
# validated result to the rendered PR body, with one resumable command
# (harmon-devkit#1919).
#
# Usage: drive-handoff.sh --repo OWNER/REPO --pr N --slate ID --session ID
#   --run-id ID --result FILE --actor-id ID [--adjudication FILE]
#   [--codex-state FILE --codex-repo-dir DIR] [--sections LIST]
#   [--repo-root DIR] [--owner-token TOKEN]
#
# Run it in the lane's worktree (or name it with --repo-root). --result is the
# integrator's result file, unchanged. --actor-id is the GitHub account that
# posts the round's evidence. --sections defaults to deferred-findings. The
# owner token may come from RUN_RECORD_OWNER_TOKEN.
# In order, each step skipped when the run record shows it already done:
#   1. capture the run's branch head and active generation, prove the slate
#      owns the run and the token owns the slate lock, and require integration
#      to be the active stage with this PR bound;
#   2. validate the result and take its `payload.collection` as is, before
#      anything is written. Only `continue`, or a judgment request that names
#      no pending predicate (ci-pending, review-pending, read-failed), goes on
#      to the receipt. A pending, retry or stop result is answered by its own
#      `next_action`, a judgment request that names a pending predicate by
#      what its collection still owes (below), and nothing is retained; a
#      result without the record is refused. Only a complete collection can
#      end in exit 0. No evidence is collected again;
#   3. require the result's head, the branch head and the live PR head to be
#      one commit on an open draft; for a result not yet retained, also require
#      step 7's body conditions now, so a stale result is never retained;
#   4. retain the result with `run-record.mjs receipt`, which validates the
#      whole run record first, so an invalid record (a hand-written settlement,
#      for one) is never published from;
#   5. record a supplied --adjudication with `run-record.mjs adjudicate`; with
#      findings and no adjudication, stop for the owner. This command never
#      writes an adjudication of its own, an empty one included;
#   6. for an adjudicated round with no registered issue marker, build the
#      round's evidence from the retained pass and adjudication and publish it
#      through review/assets/post-evidence.sh. A result whose collection is
#      incomplete stops here with what it still owes (below);
#   7. require the live review-activity fingerprint to equal the result's
#      final snapshot, or the value this command derived for its own earlier
#      body publish, and the PR body to carry no hand-written copy of a
#      section being published outside the managed markers; then run
#      `render-dev-flow.sh publish` and check the activity it left.
# A judgment is requested only for a result this command has retained and
# whose adjudication is not yet recorded. It never asks for a decision it
# could not record (a result the receipt cannot admit) or one the record
# already holds. In both cases the answer is what the collection still owes,
# by the rule the integrator applies to a result with no findings: wait on
# the named predicates, retry when only review activity moved, or stop on a
# moved head or a spent retry.
# Review activity is the readiness gate's five-surface fingerprint, computed
# here with the gate's own projections. A body edit this command makes is the
# only activity it accepts as its own, and that value is derived, never read
# back: the pre-publish read with the body the publish verified, changed only
# inside the managed sections. A read after the publish that differs is
# someone else's activity and stops the handoff (exit 14), whether or not the
# publish changed the body. So does an interrupted publish whose value was
# never recorded; the next integrator result then completes the handoff. The
# writer
# admits a later result only once the earlier round has its adjudication
# document, so a clean round followed by another pass first needs the owner's
# (empty) adjudication, recorded by re-running with --adjudication.
#
# Stdout is one stage-outcome.v1 document whenever the run, its generation and
# the head were established; diagnostics go to stderr. The outcome's evidence
# names the retained pass, the integrator-pass ordinal and each review cycle
# from their own fields, and for a judgment stop every finding id.
#
# Exit codes:
#   0  handoff rendered: receipt, adjudication, evidence and PR body are current
#   2  indeterminate or refused: usage, run state, or a failed step or read
#   10 judgment needed: the retained result's findings have no recorded
#      adjudication
#   11 waiting: the result, or what its collection still owes, names a
#      predicate that is still pending
#   12 retry: the result, or what its collection still owes, asks for the one
#      bounded collection retry
#   13 the result is not a handoff: blocked, a stop, no collection record, a
#      duplicate wakeup that retained no pass, or an adjudicated collection
#      that owes a stop
#   14 stale: the head or the review activity moved since the final snapshot
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec node "$asset_dir/drive-handoff.mjs" "$@"
