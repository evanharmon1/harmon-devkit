#!/usr/bin/env bash
# test-triage-skill.sh — unit-test the triage skill's contract scripts. Fully
# offline: every `gh` call goes to a PATH-stubbed gh driven by fixture files,
# and the wrapper's model run goes to a PATH-stubbed claude.
#
# What this keeps honest (issue #455's [CI] criteria):
#   - the write-allowlist is computed from label-registry.json (agent-writable,
#     v1 scope, retired excluded) with the gh-label fallback
#   - the never-list refuses foreman:/rigor:/tier:/method:/claim:/suggest:/
#     agent:* even when a hostile manifest grants them
#   - work-type labels are refused on org repos (native Type owns them there)
#   - needs-triage is removed only when classification is complete
#   - --execute is inert without the wrapper-owned TRIAGE_EXECUTE=1 env gate
#   - the rolling report is idempotent, upserts only its marker-carrying
#     issue, and the scan excludes it from triage (self-exclusion)
#
# Run via `task test:triage-skill`.
set -euo pipefail
cd "$(dirname "$0")/.."

apply="./ai/skills/universal/triage/assets/triage-apply.sh"
scan="./ai/skills/universal/triage/assets/triage-scan.sh"
report="./ai/skills/universal/triage/assets/triage-report.sh"
wrapper="./scripts/triage.sh"
repo="testowner/testrepo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub_dir="$tmp/fixtures"
mkdir -p "$tmp/bin" "$stub_dir"

# ── gh stub ──────────────────────────────────────────────────────────────────
# Emulates exactly the call shapes the triage scripts make. Fixture files live
# in GH_STUB_DIR; every invocation is appended to GH_STUB_LOG. Writes are
# logged, drained, and succeed.
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_STUB_LOG:?}"
[ -t 0 ] || cat >/dev/null
q=""
state=""
prev=""
for a in "$@"; do
    case "$prev" in
    -q) q="$a" ;;
    --state) state="$a" ;;
    esac
    prev="$a"
done
emit() {
    if [ -n "$q" ]; then jq -r "$q" <"$1"; else cat "$1"; fi
}
case "${1:-} ${2:-}" in
"api user")
    printf '%s\n' "${GH_STUB_VIEWER:-testowner}"
    ;;
"api graphql")
    [ "${GH_STUB_NATIVE_TYPE:-}" = "ERROR" ] && exit 1
    printf '%s\n' "${GH_STUB_NATIVE_TYPE:-}"
    ;;
api\ repos/*)
    printf '%s\n' "${GH_STUB_OWNER_TYPE:?}"
    ;;
"label list") emit "${GH_STUB_DIR:?}/labels.json" ;;
"issue list") emit "${GH_STUB_DIR:?}/issues-${state:?}.json" ;;
"issue view") emit "${GH_STUB_DIR:?}/issue-${3:?}.json" ;;
"repo view") printf '%s\n' "${GH_STUB_REPO:?}" ;;
"issue edit" | "issue create") ;;
*)
    echo "gh stub: unexpected call: $*" >&2
    exit 97
    ;;
esac
STUB
# claude stub for the wrapper test: record argv and the env gate's value.
cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
    echo "  --setting-sources <sources>"
    exit 0
fi
printf '%s\n' "ARGS: $*" >>"${GH_STUB_LOG:?}"
printf '%s\n' "TRIAGE_EXECUTE=${TRIAGE_EXECUTE:-unset}" >>"${GH_STUB_LOG:?}"
printf '%s\n' "TRIAGE_REPO=${TRIAGE_REPO:-unset}" >>"${GH_STUB_LOG:?}"
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/claude"

export GH_STUB_DIR="$stub_dir"
export GH_STUB_LOG="$tmp/gh.log"
export GH_STUB_OWNER_TYPE="User"
: >"$GH_STUB_LOG"

# run CMD... -> echoes the exit code; output lands in $tmp/out.
run() {
    _rc=0
    PATH="$tmp/bin:$PATH" "$@" >"$tmp/out" 2>&1 || _rc=$?
    echo "$_rc"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
manifest="$tmp/label-registry.json"
cat >"$manifest" <<'JSON'
{
  "schema_version": 1,
  "families": [
    {"family": "workflow", "prefix": null, "axis": "workflow",
     "writers": ["human"],
     "values": [
       {"value": "needs-triage", "writers": ["human", "agent"]},
       {"value": "blocked"}]},
    {"family": "work-type", "prefix": null, "axis": "work-type",
     "writers": ["human", "agent"],
     "values": [
       {"value": "bug"}, {"value": "feature"},
       {"value": "enhancement", "retired": true}]},
    {"family": "area", "prefix": "area", "axis": "classification",
     "writers": ["human", "agent"], "exclusive": true,
     "values": [{"value": "ci"}, {"value": "tasks"}]},
    {"family": "layer", "prefix": "layer", "axis": "classification",
     "writers": ["human", "agent"], "exclusive": true,
     "values": [{"value": "ui"}]},
    {"family": "domain", "prefix": "domain", "axis": "classification",
     "writers": ["human", "agent"], "exclusive": true,
     "values": [{"value": "delivery"}, {"value": "auth"}]},
    {"family": "rigor", "prefix": "rigor", "axis": "strategy",
     "writers": ["human"], "values": [{"value": "deep"}]},
    {"family": "provenance", "prefix": null, "axis": "provenance",
     "writers": ["human", "agent"], "values": [{"value": "ai-generated"}]},
    {"family": "claim", "prefix": "claim", "axis": "model",
     "writers": ["agent"], "values": [{"value": "claude"}]}
  ]
}
JSON
# A hostile manifest that grants agents rigor:* — scope + never-list must hold.
evil="$tmp/evil-registry.json"
jq '.families |= map(if .family == "rigor"
    then .writers = ["human", "agent"] else . end)' \
    "$manifest" >"$evil"

echo "==> allowlist: manifest mode computes agent-writable v1 scope"
[ "$(run "$apply" allowlist --manifest "$manifest")" = 0 ] ||
    fail "allowlist should succeed: $(cat "$tmp/out")"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area:ci area:tasks bug domain:auth domain:delivery feature \
    layer:ui needs-triage | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 || fail "allowlist mismatch"

echo "==> allowlist: excludes retired, human-only, and out-of-scope values"
for absent in enhancement rigor:deep blocked ai-generated claim:claude; do
    grep -qx "$absent" "$tmp/got" && fail "$absent must not be allowlisted"
done

echo "==> allowlist: a hostile manifest cannot widen the v1 scope"
[ "$(run "$apply" allowlist --manifest "$evil")" = 0 ] || fail "evil allowlist ran"
grep -qx "rigor:deep" "$tmp/out" && fail "rigor:deep leaked into the allowlist"

echo "==> allowlist: gh fallback = axis prefixes + fixed work-type vocabulary"
cat >"$stub_dir/labels.json" <<'JSON'
[{"name": "area:ci", "description": ""}, {"name": "layer:ui", "description": ""},
 {"name": "rigor:deep", "description": ""}, {"name": "bug", "description": ""},
 {"name": "enhancement", "description": ""},
 {"name": "needs-triage", "description": ""}]
JSON
[ "$(run "$apply" allowlist --repo "$repo" --manifest "$tmp/nope.json")" = 0 ] ||
    fail "fallback allowlist should succeed: $(cat "$tmp/out")"
sort "$tmp/out" >"$tmp/got"
printf '%s\n' area:ci bug layer:ui needs-triage | sort >"$tmp/want"
diff -u "$tmp/want" "$tmp/got" >&2 ||
    fail "fallback mismatch (enhancement/rigor must be out)"

# Issue fixtures for the label subcommand.
cat >"$stub_dir/issue-10.json" <<'JSON'
{"labels": [{"name": "needs-triage"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-11.json" <<'JSON'
{"labels": [{"name": "area:tasks"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-12.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "domain:auth"},
            {"name": "domain:delivery"}, {"name": "bug"}], "body": "plain"}
JSON
cat >"$stub_dir/issue-13.json" <<'JSON'
{"labels": [{"name": "needs-triage"}, {"name": "bug"}, {"name": "area:ci"}],
 "body": "plain"}
JSON

echo "==> label: never-list refuses even what a hostile manifest grants"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add rigor:deep \
    --manifest "$evil")" = 4 ] || fail "rigor:deep must exit 4"
for l in foreman:approved tier:apex method:plan claim:claude suggest:claude \
    agent:claude-code; do
    [ "$(run "$apply" label --repo "$repo" --issue 10 --add "$l" \
        --manifest "$manifest")" = 4 ] || fail "$l must exit 4"
done

echo "==> label: off-allowlist labels are refused"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add ai-generated \
    --manifest "$manifest")" = 4 ] || fail "ai-generated must exit 4"

echo "==> label: dry-run prints WOULD lines and writes nothing"
: >"$GH_STUB_LOG"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add area:ci --add bug \
    --manifest "$manifest")" = 0 ] || fail "dry-run failed: $(cat "$tmp/out")"
grep -q "DRY-RUN would add 'area:ci'" "$tmp/out" || fail "missing WOULD area:ci"
grep -q "DRY-RUN would add 'bug'" "$tmp/out" || fail "missing WOULD bug"
grep -q "issue edit" "$GH_STUB_LOG" && fail "dry-run must not edit"

echo "==> label: work-type on an org repo is refused, axes still pass"
GH_STUB_OWNER_TYPE="Organization"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add bug \
    --manifest "$manifest")" = 5 ] || fail "org work-type must exit 5"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add area:ci \
    --manifest "$manifest")" = 0 ] || fail "org axis add must pass"
GH_STUB_OWNER_TYPE="User"

echo "==> label: a second work-type label is refused (triage fills, never stacks)"
[ "$(run "$apply" label --repo "$repo" --issue 13 --add feature \
    --manifest "$manifest")" = 4 ] || fail "feature over bug must exit 4"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add bug --add feature \
    --manifest "$manifest")" = 4 ] || fail "two work-types in one call must exit 4"

echo "==> label: a mismatched --repo is refused when the run is bound"
[ "$(run env TRIAGE_REPO="$repo" "$apply" label --repo other/elsewhere \
    --issue 10 --add area:ci --manifest "$manifest")" = 4 ] ||
    fail "unbound repo write must exit 4"
[ "$(run env TRIAGE_REPO="$repo" "$apply" label --repo "$repo" --issue 10 \
    --add area:ci --manifest "$manifest")" = 0 ] ||
    fail "bound repo write must pass"

echo "==> label: exclusive axes refuse a second value"
[ "$(run "$apply" label --repo "$repo" --issue 11 --add area:ci \
    --manifest "$manifest")" = 4 ] || fail "second area label must exit 4"

echo "==> label: --remove accepts only needs-triage"
[ "$(run "$apply" label --repo "$repo" --issue 10 --remove area:ci \
    --manifest "$manifest")" = 2 ] || fail "--remove area:ci must exit 2"

echo "==> label: needs-triage removal is refused on a conflicted axis"
[ "$(run "$apply" label --repo "$repo" --issue 12 --remove needs-triage \
    --inapplicable area --inapplicable layer \
    --manifest "$manifest")" = 6 ] || fail "conflicted axis must exit 6"

echo "==> label: needs-triage removal is refused without a work type"
[ "$(run "$apply" label --repo "$repo" --issue 10 --remove needs-triage \
    --inapplicable area --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "missing work type must exit 6"

echo "==> label: needs-triage removal passes when classification is complete"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 0 ] || fail "complete removal: $(cat "$tmp/out")"
grep -q "DRY-RUN would remove 'needs-triage'" "$tmp/out" ||
    fail "missing WOULD remove"
grep -q "attested inapplicable: layer" "$tmp/out" || fail "missing attestation"

echo "==> label: org removal needs a native Type; unreadable Type refuses"
GH_STUB_OWNER_TYPE="Organization"
export GH_STUB_NATIVE_TYPE=""
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "org without Type must exit 6"
export GH_STUB_NATIVE_TYPE="ERROR"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 6 ] || fail "unreadable Type must exit 6"
export GH_STUB_NATIVE_TYPE="Bug"
[ "$(run "$apply" label --repo "$repo" --issue 13 --remove needs-triage \
    --inapplicable layer --inapplicable domain \
    --manifest "$manifest")" = 0 ] || fail "org with Type should pass"
unset GH_STUB_NATIVE_TYPE
GH_STUB_OWNER_TYPE="User"

echo "==> label: --execute is inert without TRIAGE_EXECUTE=1"
[ "$(run "$apply" label --repo "$repo" --issue 10 --add area:ci --execute \
    --manifest "$manifest")" = 2 ] || fail "--execute without env must exit 2"
grep -q "issue edit" "$GH_STUB_LOG" && fail "gated execute must not edit"

echo "==> label: --execute with the env gate edits and reports APPLIED"
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$apply" label --repo "$repo" --issue 10 \
    --add area:ci --execute --manifest "$manifest")" = 0 ] ||
    fail "gated execute failed: $(cat "$tmp/out")"
grep -q "APPLIED add 'area:ci'" "$tmp/out" || fail "missing APPLIED"
grep -q -- "--add-label area:ci" "$GH_STUB_LOG" || fail "edit not issued"

echo "==> native-type: prints none for an unset Type"
export GH_STUB_NATIVE_TYPE=""
[ "$(run "$apply" native-type --repo "$repo" --issue 10)" = 0 ] ||
    fail "native-type failed"
grep -qx "none" "$tmp/out" || fail "expected none"
unset GH_STUB_NATIVE_TYPE

# ── report ───────────────────────────────────────────────────────────────────
marker='<!-- harmon-triage-report -->'
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 90, "body": "no marker here", "author": {"login": "testowner"}},
 {"number": 99, "body": "$marker\nrolling report",
  "author": {"login": "testowner"}}]
JSON

echo "==> report find: locates the marker-carrying issue"
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "find failed"
grep -qx "99" "$tmp/out" || fail "expected 99, got: $(cat "$tmp/out")"

echo "==> report find: none without a marker; ambiguous refuses"
cat >"$stub_dir/issues-open.json" <<'JSON'
[{"number": 90, "body": "no marker", "author": {"login": "testowner"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "find(none) failed"
grep -qx "none" "$tmp/out" || fail "expected none"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 98, "body": "$marker", "author": {"login": "testowner"}},
 {"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 2 ] || fail "ambiguous must exit 2"

echo "==> report find: a stranger's forged marker is not the report"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 66, "body": "$marker forged", "author": {"login": "attacker"}},
 {"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "forged find failed"
grep -qx "99" "$tmp/out" || fail "forged marker must be ignored, want 99"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 66, "body": "$marker forged", "author": {"login": "attacker"}}]
JSON
[ "$(run "$report" find --repo "$repo")" = 0 ] || fail "forged-only find failed"
grep -qx "none" "$tmp/out" || fail "a forged-only marker must read as none"

entries="$tmp/entries.md"
cat >"$entries" <<'MD'
### #12 — axis-conflict: two domain labels
<!-- triage-entry:12 -->
- Evidence: domain:auth and domain:delivery both applied.
- Suggested action: keep one; needs-triage retained.

## Title violations

- #30 — some: prefixed title
MD

echo "==> report sync: malformed entries (heading without key) are refused"
printf '### #7 — broken\nno key line\n' >"$tmp/bad.md"
[ "$(run "$report" sync --repo "$repo" --entries-file "$tmp/bad.md")" = 2 ] ||
    fail "malformed entries must exit 2"

echo "==> report sync: dry-run assembles the body and writes nothing"
cat >"$stub_dir/issues-open.json" <<'JSON'
[{"number": 90, "body": "no marker", "author": {"login": "testowner"}}]
JSON
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries")" = 0 ] || fail "sync dry-run: $(cat "$tmp/out")"
grep -q "DRY-RUN would create" "$tmp/out" || fail "expected create path"
grep -qF "$marker" "$tmp/out" || fail "body must carry the marker"
grep -q "triage-entry:12" "$tmp/out" || fail "body must carry the entry key"
grep -qE "issue (edit|create)" "$GH_STUB_LOG" && fail "dry-run must not write"

echo "==> report sync: re-runs are idempotent (same entries, same body)"
run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries" >/dev/null
cp "$tmp/out" "$tmp/body1"
run env TRIAGE_NOW=2026-01-01 "$report" sync --repo "$repo" \
    --entries-file "$entries" >/dev/null
diff -u "$tmp/body1" "$tmp/out" >&2 || fail "sync is not idempotent"

echo "==> report sync: updates only a live marker-carrying issue"
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "body": "$marker", "author": {"login": "testowner"}}]
JSON
cat >"$stub_dir/issue-99.json" <<'JSON'
{"labels": [], "body": "marker was edited away"}
JSON
[ "$(run env TRIAGE_EXECUTE=1 "$report" sync --repo "$repo" \
    --entries-file "$entries" --execute)" = 4 ] ||
    fail "marker-less live body must exit 4"
cat >"$stub_dir/issue-99.json" <<JSON
{"labels": [], "body": "$marker\nold body"}
JSON
: >"$GH_STUB_LOG"
[ "$(run env TRIAGE_EXECUTE=1 "$report" sync --repo "$repo" \
    --entries-file "$entries" --execute)" = 0 ] ||
    fail "marker-carrying update failed: $(cat "$tmp/out")"
grep -q "issue edit 99" "$GH_STUB_LOG" || fail "edit of #99 not issued"

echo "==> report sync: --execute without the env gate is refused"
[ "$(run "$report" sync --repo "$repo" --entries-file "$entries" \
    --execute)" = 2 ] || fail "sync --execute without env must exit 2"

echo "==> report sync: a mismatched --repo is refused when the run is bound"
[ "$(run env TRIAGE_REPO="$repo" "$report" sync --repo other/elsewhere \
    --entries-file "$entries")" = 4 ] || fail "unbound repo sync must exit 4"

# ── scan ─────────────────────────────────────────────────────────────────────
cat >"$stub_dir/issues-open.json" <<JSON
[{"number": 99, "title": "Triage report", "body": "$marker",
  "author": {"login": "testowner"},
  "labels": [], "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z", "assignees": []},
 {"number": 23, "title": "Typed but one axis missing",
  "author": {"login": "testowner"},
  "labels": [{"name": "bug"}, {"name": "layer:ui"}, {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 20, "title": "gauntlet: something is broken in the gate",
  "labels": [{"name": "claim:claude"}, {"name": "needs-triage"}],
  "createdAt": "2020-01-01T00:00:00Z", "updatedAt": "2020-01-02T00:00:00Z",
  "assignees": [{"login": "someone"}], "body": ""},
 {"number": 21, "title": "Short title",
  "labels": [{"name": "bug"}, {"name": "domain:auth"},
             {"name": "domain:delivery"}, {"name": "area:ci"},
             {"name": "layer:ui"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""},
 {"number": 22, "title": "Fully classified and quiet",
  "labels": [{"name": "bug"}, {"name": "area:ci"}, {"name": "layer:ui"},
             {"name": "domain:auth"}],
  "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z",
  "assignees": [], "body": ""}]
JSON
cat >"$stub_dir/issues-closed.json" <<'JSON'
[{"number": 40, "title": "done but unticked", "stateReason": "COMPLETED",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [],
  "body": "- [x] one\n- [ ] two\n- [ ] three"},
 {"number": 41, "title": "dup close", "stateReason": "DUPLICATE",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [], "body": "closed as dup"},
 {"number": 42, "title": "clean close", "stateReason": "COMPLETED",
  "closedAt": "2026-01-01T00:00:00Z", "labels": [], "body": "- [x] all done"}]
JSON

echo "==> scan: emits facts, flags, and excludes the report issue"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "scan failed: $(cat "$tmp/out")"
scan_out="$tmp/scan.json"
cp "$tmp/out" "$scan_out"
jq -e '.report_issue == 99' "$scan_out" >/dev/null || fail "report_issue"
jq -e '[.open[].number] | index(99) == null' "$scan_out" >/dev/null ||
    fail "report issue must be excluded from open"
jq -e '[.closed_flagged[].number] | index(99) == null' "$scan_out" \
    >/dev/null || fail "report issue must be excluded from closed"
jq -e '.open[] | select(.number == 20) | .flags | index("stale-claim-candidate")' \
    "$scan_out" >/dev/null || fail "stale claim flag missing"
jq -e '.open[] | select(.number == 20) | .flags | index("title-prefixed")' \
    "$scan_out" >/dev/null || fail "title-prefixed flag missing"
jq -e '.open[] | select(.number == 21) | .axis_state.domain == "conflict"' \
    "$scan_out" >/dev/null || fail "domain conflict missing"
jq -e '.open[] | select(.number == 21) | .flags | index("axis-conflict:domain")' \
    "$scan_out" >/dev/null || fail "axis-conflict flag missing"
jq -e '[.open[].number] | index(22) == null' "$scan_out" >/dev/null ||
    fail "quiet issue must be filtered without --all"
jq -e '.closed_flagged | length == 2' "$scan_out" >/dev/null ||
    fail "expected exactly two flagged closed issues"
jq -e '.closed_flagged[] | select(.number == 40) | .unticked_criteria == 2' \
    "$scan_out" >/dev/null || fail "unticked count wrong"
jq -e '.work_type_values | sort == ["bug", "feature"]' "$scan_out" \
    >/dev/null || fail "work_type_values wrong"

echo "==> scan: a bare missing axis does not re-add needs-triage"
jq -e '.open[] | select(.number == 23)
       | (.flags | index("axis-missing:area") != null)
         and (.flags | index("missing-needs-triage") == null)' \
    "$scan_out" >/dev/null ||
    fail "typed issue missing one axis must not be needs-triage-worthy"
jq -e '.open[] | select(.number == 21) | .flags | index("missing-needs-triage")' \
    "$scan_out" >/dev/null || fail "a conflicted axis must still re-add"

echo "==> scan: org repos never re-add needs-triage for a missing work-type label"
GH_STUB_OWNER_TYPE="Organization"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest")" = 0 ] ||
    fail "org scan failed: $(cat "$tmp/out")"
jq -e '[.open[] | select(.work_type == []) | .flags[]]
       | index("missing-needs-triage") == null' "$tmp/out" >/dev/null ||
    fail "org repo must not flag missing-needs-triage on empty work-type"
GH_STUB_OWNER_TYPE="User"

echo "==> scan: --all includes the quiet issue"
[ "$(run "$scan" --repo "$repo" --manifest "$manifest" --all)" = 0 ] ||
    fail "scan --all failed"
jq -e '[.open[].number] | index(22) != null' "$tmp/out" >/dev/null ||
    fail "--all must include the quiet issue"

# ── wrapper ──────────────────────────────────────────────────────────────────
export GH_STUB_REPO="$repo"

echo "==> wrapper: dry-run forces TRIAGE_EXECUTE=0 and a DRY-RUN prompt"
: >"$GH_STUB_LOG"
[ "$(run "$wrapper")" = 0 ] || fail "wrapper dry-run failed: $(cat "$tmp/out")"
grep -q "TRIAGE_EXECUTE=0" "$GH_STUB_LOG" || fail "env gate not forced to 0"
grep -q "TRIAGE_REPO=$repo" "$GH_STUB_LOG" || fail "run must be repo-bound"
grep -q "DRY-RUN" "$GH_STUB_LOG" || fail "prompt must state DRY-RUN"
grep -q -- "--model haiku" "$GH_STUB_LOG" || fail "default model must be haiku"
grep -q -- "--setting-sources" "$GH_STUB_LOG" ||
    fail "worker must run with settings isolated"

echo "==> wrapper: --execute without a terminal is refused"
[ "$(run "$wrapper" --execute)" = 2 ] ||
    fail "non-interactive --execute must exit 2"

echo "All triage skill tests passed."
