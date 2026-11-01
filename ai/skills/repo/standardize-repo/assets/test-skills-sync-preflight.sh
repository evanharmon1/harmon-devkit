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
    [[ " $* " == *' --head bot/sync-harmon-devkit '* ]] || exit 1
    [[ " $* " == *' --base main '* ]] || exit 1
    [[ ${GH_FAIL:-} != pr ]] || exit 1
    # Simulate GitHub filtering out a PR whose base is another branch.
    if [[ ${GH_PRS:-} == empty || ${GH_PRS:-} == other-base ]]; then echo '[]'; exit; fi
    if [[ ${GH_PRS:-} == full ]]; then python3 -c 'import json; print(json.dumps([{}] * 1000))'; exit; fi
    printf '%s\n' '[{"number":42,"title":"Edited sync title","url":"https://example.invalid/42","headRefName":"bot/sync-harmon-devkit","isCrossRepository":false},{"number":43,"title":"fix: sync harmon-devkit skills to v0.60.0","url":"https://example.invalid/43","headRefName":"bot/sync-harmon-devkit","isCrossRepository":true}]'
elif [[ "$1 $2" == 'release view' ]]; then
    [[ ${GH_FAIL:-} != release ]] || exit 1
    printf '{"tagName":"%s"}\n' "${GH_TAG:-v0.60.0}"
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
assert obj['open_sync_prs'][0]['title'] == 'Edited sync title'
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
run_case v0.61.0 absorb supersede leave 'ahead of v0.60.0'
make_decision merge-first
GH_PRS=other-base "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out"
python3 - "$fixture/out" <<'PY'
import json, sys
obj = json.loads(open(sys.argv[1]).readline())
assert obj['open_sync_prs'] == [] and obj['planned_action']['sync_prs'] == 'none'
PY
printf 'other: value\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'no minimum'
"$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out"
python3 - "$fixture/out" <<'PY'
import json, sys
obj = json.loads(open(sys.argv[1]).readline())
assert obj['verdict'] == 'unknown' and obj['reason'] == 'no-declared-minimum'
assert obj['pin'] == 'v0.61.0' and obj['pin_lag'] == 'ahead of v0.60.0'
PY
printf 'source:\n  ref: v0.1.0\n  ref: v0.2.0\n' >"$fixture/pin.yml"
"$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out"
python3 - "$fixture/out" <<'PYTEST'
import json, sys
obj = json.loads(open(sys.argv[1]).readline())
assert obj['pin'] is None and obj['pin_reason'] == 'duplicate-key' and obj['pin_lag'] == 'unknown'
PYTEST
fail_case() {
    local reason="$1"
    shift
    if env "$@" "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out" 2>"$fixture/err"; then exit 1; fi
    grep -q "$reason" "$fixture/err"
    test ! -s "$fixture/out"
}
fail_case 'may be truncated' GH_PRS=full
fail_case 'command failed' GH_FAIL=pr
fail_case 'command failed' GH_FAIL=release
fail_case 'not a stable version tag' GH_TAG=v0.60.0-rc.1
mkdir -p "$fixture/no-yq"
real_yq="$(command -v yq)"
cat >"$fixture/no-yq/yq" <<'YQ'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then
    if [[ -e $YQ_COUNT ]]; then exit 1; fi
    touch "$YQ_COUNT"
fi
exec "$REAL_YQ" "$@"
YQ
chmod +x "$fixture/no-yq/yq"
fail_case 'yq-unavailable' PATH="$fixture/no-yq:$PATH" REAL_YQ="$real_yq" YQ_COUNT="$fixture/yq-count"
make_decision missing
if "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out" 2>"$fixture/err"; then exit 1; fi
grep -q 'missing ruling key: skills_sync' "$fixture/err"
test ! -s "$fixture/out"
printf 'skills sync preflight tests passed\n'
