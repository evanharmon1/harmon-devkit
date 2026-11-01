#!/usr/bin/env bash
set -euo pipefail
assets="$(cd "$(dirname "$0")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/template" "$fixture/bin"
git -C "$fixture/template" init -q
git -C "$fixture/template" config user.name Test
git -C "$fixture/template" config user.email test@example.invalid
printf '_min_harmon_devkit_skills: v0.58.0\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm fixture
cat >"$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1 $2" == 'pr list' ]]; then
    printf '%s\n' '[{"number":42,"title":"fix: sync harmon-devkit skills to v0.60.0","url":"https://example.invalid/42","headRefName":"bot/sync-harmon-devkit","headRepository":{"nameWithOwner":"example/repo"}},{"number":43,"title":"fix: sync harmon-devkit skills to v0.60.0","url":"https://example.invalid/43","headRefName":"bot/sync-harmon-devkit","headRepository":{"nameWithOwner":"fork/repo"}}]'
elif [[ "$1 $2" == 'release view' ]]; then
    printf '%s\n' '{"tagName":"v0.60.0"}'
else exit 1; fi
GH
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"
make_decision() {
    python3 - "$fixture/decisions.json" "$1" <<'PY'
import json, sys
entries = [] if sys.argv[2] == 'missing' else [dict(id='SYNC', scope='release', ruling=json.dumps(dict(schema_version=1, key='skills_sync', answer=sys.argv[2])), approved_by='maintainer', approved_on='2026-10-30')]
with open(sys.argv[1], 'w') as f:
    json.dump(dict(schema_version=1, fleet=[], releases={'v1': entries}), f)
PY
}
run_case() {
    local pin="$1" ruling="$2" expected_action="$3" expected_pin="$4" expected_lag="$5"
    printf 'source:\n  ref: %s\n' "$pin" >"$fixture/pin.yml"
    make_decision "$ruling"
    "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out"
    python3 - "$fixture/out" "$expected_action" "$expected_pin" "$expected_lag" <<'PY'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 2
obj = json.loads(lines[0])
assert [p['number'] for p in obj['open_sync_prs']] == [42]
assert obj['planned_action']['sync_prs'] == sys.argv[2]
assert obj['planned_action']['pin'] == sys.argv[3]
assert obj['pin_lag'] == sys.argv[4]
assert ('bump-to-minimum' != sys.argv[3]) or obj['planned_action']['target'] == 'v0.58.0'
assert sys.argv[4] in lines[1] and '#42' in lines[1]
PY
}
run_case v0.57.0 merge-first wait-for-merge bump-to-minimum 'behind v0.60.0'
run_case v0.58.0 absorb supersede leave 'behind v0.60.0'
run_case v0.59.0 merge-first wait-for-merge leave 'behind v0.60.0'
run_case v0.60.0 absorb supersede leave current
make_decision missing
if "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out" 2>"$fixture/err"; then exit 1; fi
grep -q 'missing ruling key: skills_sync' "$fixture/err"
test ! -s "$fixture/out"
printf 'skills sync preflight tests passed\n'
