#!/usr/bin/env bash
# test-shared-issue-assets.sh — assert no drift across shared issue assets
# (issue #1064, AC5).
#
# Asserts that the 4 shared assets across triage, breakdown, track-work, and groom:
#   1. Issue scan projection: ai/skills/universal/issue-title-support/assets/issue-conformance.jq
#   2. Title validation: ai/skills/universal/issue-title-support/assets/issue-title.jq
#   3. Label vocabulary discovery: ai/skills/universal/triage/assets/triage-apply.sh
#   4. Plan-row validation: ai/skills/universal/groom/assets/validate-plan-row.sh
# are referenced without drifting duplicate implementations, and verifies that
# triage-scan and groom-scan compute identical conformance projections for a shared fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> checking existence and permissions of shared assets"
[ -f "ai/skills/universal/issue-title-support/assets/issue-conformance.jq" ] ||
    fail "issue-conformance.jq must exist"
[ -f "ai/skills/universal/issue-title-support/assets/issue-title.jq" ] ||
    fail "issue-title.jq must exist"
[ -x "ai/skills/universal/triage/assets/triage-apply.sh" ] ||
    fail "triage-apply.sh must exist and be executable"
[ -x "ai/skills/universal/groom/assets/validate-plan-row.sh" ] ||
    fail "validate-plan-row.sh must exist and be executable"

echo "==> checking triage-scan.sh and groom-scan.sh reuse issue-conformance.jq"
# Reuse means loading that one file, whether by include or by inlining its
# text; what must never appear is a second copy of the projection. jq 1.8
# aborts on the two-level include chain (see the comment in either scan
# script), so both inline the file instead.
grep -q 'cat "$title_module_dir/issue-conformance.jq"' "ai/skills/universal/triage/assets/triage-scan.sh" ||
    fail "triage-scan.sh must load the shared issue-conformance.jq"
grep -q 'cat "$title_module_dir/issue-conformance.jq"' "ai/skills/universal/groom/assets/groom-scan.sh" ||
    fail "groom-scan.sh must load the shared issue-conformance.jq"
# Anchored to a statement, not prose: both scripts explain the chain in a
# comment that names the include they no longer use.
grep -qE '^[[:space:]]*include "issue-conformance";' "ai/skills/universal/triage/assets/triage-scan.sh" &&
    fail "triage-scan.sh must not include issue-conformance — jq 1.8 aborts on that two-level chain"
grep -qE '^[[:space:]]*include "issue-conformance";' "ai/skills/universal/groom/assets/groom-scan.sh" &&
    fail "groom-scan.sh must not include issue-conformance — jq 1.8 aborts on that two-level chain"
grep -q 'issue_conformance(' "ai/skills/universal/triage/assets/triage-scan.sh" ||
    fail "triage-scan.sh must invoke issue_conformance"
grep -q 'issue_conformance(' "ai/skills/universal/groom/assets/groom-scan.sh" ||
    fail "groom-scan.sh must invoke issue_conformance"

echo "==> checking shared title validation reuse"
# Both scan scripts reach issue-title through the projection they inline, so
# the include that matters is the projection's own.
grep -q 'include "issue-title";' "ai/skills/universal/issue-title-support/assets/issue-conformance.jq" ||
    fail "issue-conformance.jq must include issue-title"

echo "==> checking groom-scan.sh reuses triage label discovery"
grep -q 'triage-apply.sh' "ai/skills/universal/groom/assets/groom-scan.sh" ||
    fail "groom-scan.sh must reference triage-apply.sh for label discovery"

echo "==> checking groom-apply.sh uses validate-plan-row.sh in pass 1"
grep -q 'validate-plan-row.sh' "ai/skills/universal/groom/assets/groom-apply.sh" ||
    fail "groom-apply.sh must reference validate-plan-row.sh in pass 1"

echo "==> testing shared conformance projection produces identical results across callers"
fixture_issue='{
  "number": 42,
  "title": "(core): implement robust logging support",
  "body": "## Context\nSome context\n\n## Acceptance criteria\n\n- [ ] [CI] unit tests pass\n- [x] [CI] fast gate green\n- [ ] [HUMAN] operator sign-off\n",
  "labels": [{"name": "area:core"}, {"name": "domain:backend"}, {"name": "feature"}, {"name": "needs-triage"}],
  "assignees": [{"login": "alice"}],
  "createdAt": "2026-09-01T00:00:00Z",
  "updatedAt": "2026-09-10T00:00:00Z",
  "author": {"login": "alice", "type": "User"}
}'
axes_json='["area", "domain", "layer"]'
known_json='["area:core", "domain:backend", "layer:backend"]'
wt_json='["bug", "feature", "task"]'
title_module_dir="ai/skills/universal/issue-title-support/assets"

conformance_jq="$(cat "$title_module_dir/issue-conformance.jq")" ||
    fail "cannot read the shared conformance projection"

res=$(jq -n -L "$title_module_dir" \
    --argjson issue "$fixture_issue" \
    --argjson axes "$axes_json" \
    --argjson known "$known_json" \
    --argjson wt "$wt_json" "$conformance_jq"'
  issue_conformance($issue; $axes; $known; $wt; "User"; "n/a"; 14; 30)
')

[ "$(jq -r '.title_valid' <<<"$res")" = "true" ] || fail "title should be valid"
[ "$(jq -r '.criteria.total' <<<"$res")" = "3" ] || fail "total criteria should be 3"
[ "$(jq -r '.criteria.unticked_ci' <<<"$res")" = "1" ] || fail "unticked_ci should be 1"
[ "$(jq -r '.criteria.unticked_human' <<<"$res")" = "1" ] || fail "unticked_human should be 1"
[ "$(jq -r '.axis_state.area' <<<"$res")" = "ok" ] || fail "area should be ok"
[ "$(jq -r '.axis_state.domain' <<<"$res")" = "ok" ] || fail "domain should be ok"
[ "$(jq -r '.axis_state.layer' <<<"$res")" = "none" ] || fail "layer should be none"

echo "==> testing validate-plan-row.sh rejects bot issues and malformed rows"
bot_row='{"op": "close", "issue": 10, "reason": "completed", "bot_owned": true}'
set +e
./ai/skills/universal/groom/assets/validate-plan-row.sh --repo "testowner/testrepo" --row "$bot_row" >"$tmp/out" 2>"$tmp/err"
bot_rc=$?
set -e
[ "$bot_rc" -eq 4 ] || fail "validate-plan-row.sh must refuse bot-owned issue with exit 4, got $bot_rc"
grep -q "bot-authored" "$tmp/err" || fail "validate-plan-row.sh error must cite bot-authored"

dup_self_row='{"op": "close", "issue": 10, "reason": "duplicate", "comment": "duplicate of #10", "bot_owned": false}'
set +e
./ai/skills/universal/groom/assets/validate-plan-row.sh --repo "testowner/testrepo" --row "$dup_self_row" >"$tmp/out" 2>"$tmp/err"
dup_rc=$?
set -e
[ "$dup_rc" -eq 2 ] || fail "validate-plan-row.sh must refuse duplicate pointing to itself with exit 2, got $dup_rc"

echo "All shared issue assets tests passed."
