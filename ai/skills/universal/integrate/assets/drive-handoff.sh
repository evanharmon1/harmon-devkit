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
#   2. validate the result and take its `payload.collection` as is: its own
#      `next_action` answers a pending, retry, stop or blocked result before
#      anything is written, and a result without the record is refused. No
#      evidence is collected again;
#   3. require the result's head, the branch head and the live PR head to be
#      one commit on an open draft;
#   4. retain the result with `run-record.mjs receipt`, which validates the
#      whole run record first, so an invalid record (a hand-written settlement,
#      for one) is never published from;
#   5. record a supplied --adjudication with `run-record.mjs adjudicate`; with
#      findings and no adjudication, stop for the owner. This command never
#      writes an adjudication of its own, an empty one included;
#   6. for an adjudicated round with no registered issue marker, build the
#      round's evidence from the retained pass and adjudication and publish it
#      through review/assets/post-evidence.sh;
#   7. require the live review-activity fingerprint to equal the result's
#      final snapshot, or the value this command recorded after its own
#      earlier body publish, then run `render-dev-flow.sh publish` and record
#      the fingerprint the publish left.
# A body edit this command makes is the only activity it accepts as its own.
# An interrupted publish whose fingerprint was never recorded therefore reads
# as stale, and the next integrator result completes the handoff. The writer
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
#   10 judgment needed: the retained result's findings have no adjudication
#   11 waiting: the result names a predicate that is still pending
#   12 retry: the result asks for its one bounded collection retry
#   13 the result is not a handoff: blocked, a stop, no collection record, or
#      a duplicate wakeup that retained no pass
#   14 stale: the head or the review activity moved since the final snapshot
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec node "$asset_dir/drive-handoff.mjs" "$@"
