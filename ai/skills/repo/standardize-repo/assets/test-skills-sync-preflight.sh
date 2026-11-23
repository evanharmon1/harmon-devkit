#!/usr/bin/env bash
set -euo pipefail
assets="$(cd "$(dirname "$0")" && pwd)"
real_task="$(command -v task)"
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
    printf '%s\0' "$@" >"$GH_PR_ARGS"
    [[ ${GH_FAIL:-} != pr ]] || exit 1
    # Simulate GitHub filtering out a PR whose base is another branch.
    if [[ ${GH_PRS:-} == empty || ${GH_PRS:-} == other-base ]]; then echo '[]'; exit; fi
    if [[ ${GH_PRS:-} == full ]]; then python3 -c 'import json; print(json.dumps([{}] * 1000))'; exit; fi
    printf '%s\n' '[{"number":42,"title":"Edited sync title","url":"https://example.invalid/42","headRefName":"bot/sync-harmon-devkit","isCrossRepository":false},{"number":43,"title":"fix: sync harmon-devkit skills to v0.60.0","url":"https://example.invalid/43","headRefName":"bot/sync-harmon-devkit","isCrossRepository":true}]'
else exit 1; fi
GH
cat >"$fixture/bin/task" <<'TASK'
#!/usr/bin/env bash
if [[ -n ${STATUS_REAL_TASK:-} ]]; then exec "$STATUS_REAL_TASK" "$@"; fi
[[ "$1 $2 $3 $4 $5 $6" == '--silent --exit-code --output interleaved skills:status --' ]] || exit 99
printf '%s\0' "$@" >"$TASK_STATUS_ARGS"
if [[ -n ${STATUS_OUTPUT+x} ]]; then
    printf '%s\n' "$STATUS_OUTPUT"
    exit "${STATUS_EXIT:-0}"
fi
pin="$(yq -r '.source.ref' "$7")"
latest="${GH_TAG:-v0.60.0}"
if [[ ${GH_FAIL:-} == release ]]; then latest=unknown; fi
state=in-sync
code=0
case "$pin" in
v0.57.0 | v0.58.0 | v0.59.0)
    if [[ $latest == v0.60.0 ]]; then state=upstream-newer; code=12; fi ;;
esac
printf 'state=%s pinned=%s vendored=%s latest=%s\n' "$state" "$pin" "$pin" "$latest"
exit "$code"
TASK
chmod +x "$fixture/bin/task"
export TASK_STATUS_ARGS="$fixture/status-args"
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"
export GH_PR_ARGS="$fixture/pr-args"
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
run_case v0.61.0 absorb supersede leave unknown
make_decision merge-first
GH_PRS=other-base "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out"
python3 - "$fixture/out" "$GH_PR_ARGS" <<'PY'
import json, sys
args = open(sys.argv[2], 'rb').read().decode().split('\0')[:-1]
assert any(args[i:i+2] == ['--head', 'bot/sync-harmon-devkit'] for i in range(len(args)))
assert any(args[i:i+2] == ['--base', 'main'] for i in range(len(args)))
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
assert obj['pin'] == 'v0.61.0' and obj['pin_lag'] == 'unknown'
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
# Release/status uncertainty is informational, never a fleet failure or current.
printf 'source:\n  ref: v0.60.0\n' >"$fixture/pin.yml"
for kind in failed-release unstable-release; do
    if [[ $kind == failed-release ]]; then export GH_FAIL=release; else export GH_TAG=v0.60.0-rc.1; fi
    "$assets/skills-sync-preflight.sh" example/repo "$fixture/template" HEAD "$fixture/decisions.json" v1 "$fixture/pin.yml" >"$fixture/out"
    python3 - "$fixture/out" <<'PYTEST'
import json, sys
assert json.loads(open(sys.argv[1]).readline())['pin_lag'] == 'unknown'
PYTEST
    unset GH_FAIL GH_TAG
done
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
# Report-only entry uses the same status source, no decision/template/PR reads.
lag_case() {
    local state_line="$1" code="$2" expected="$3"
    STATUS_OUTPUT="$state_line" STATUS_EXIT="$code" "$assets/skills-sync-preflight.sh" --lag-only "$fixture/pin.yml" >"$fixture/out"
    python3 - "$fixture/out" "$expected" "$TASK_STATUS_ARGS" "$fixture/pin.yml" <<'PYTEST'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 1
assert json.loads(lines[0])['pin_lag'] == sys.argv[2]
args = open(sys.argv[3], 'rb').read().decode().split('\0')[:-1]
assert args == ['--silent', '--exit-code', '--output', 'interleaved', 'skills:status', '--', sys.argv[4]]
PYTEST
}
lag_case 'state=upstream-newer pinned=v0.59.0 vendored=v0.59.0 latest=v0.60.0' 12 'behind v0.60.0'
lag_case 'state=upstream-newer pinned=v1.2.3 vendored=v1.2.3 latest=v01.2.4' 12 'behind v01.2.4'
lag_case 'state=in-sync pinned=v01.02.003 vendored=v01.02.003 latest=v01.02.003' 0 current
lag_case 'state=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 0 current
lag_case 'state=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=unknown' 0 unknown
lag_case 'state=in-sync pinned=v01.02.003 vendored=v01.02.003 latest=unknown' 0 unknown
lag_case 'state=in-sync pinned=v01.02.003 vendored=v01.02.003 latest=v01.02.003-rc.1' 0 unknown
lag_case 'state=pin-moved pinned=v0.60.0 vendored=v0.59.0 latest=unknown' 11 unknown
lag_case 'state=never-vendored pinned=v0.60.0 vendored=none latest=unknown' 10 unknown
lag_case 'state=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 1 unknown
lag_case 'state=upstream-newer pinned=v0.59.0 vendored=v0.59.0 latest=v0.60.0' 0 unknown
lag_case 'garbled' 0 unknown
lag_case '' 2 unknown
# Task workflow annotations are transport metadata, never a second state.
annotation="::error title=Task 'skills:status' failed::exit status 12"
lag_case "$annotation"$'\nstate=upstream-newer pinned=v0.59.0 vendored=v0.59.0 latest=v0.60.0\n::endgroup::' 12 'behind v0.60.0'
lag_case $'::notice::status probe\nstate=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 0 current
lag_case "$annotation" 12 unknown
lag_case "$annotation"$'\ngarbled' 0 unknown
lag_case "$annotation"$'\nstate=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0\nstate=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 0 unknown
lag_case "$annotation"$'\nstate=unsupported pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 0 unknown
lag_case "$annotation"$'\nstate=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=unknown' 0 unknown
lag_case "$annotation"$'\nstate=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 12 unknown
lag_case "$annotation"$'\nstate=upstream-newer pinned=v0.59.0 vendored=v0.59.0 latest=v0.60.0' 0 unknown
lag_case $'progress\nstate=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0' 0 unknown
# The adapter reads only: the caller's manifest remains unchanged.
printf 'source:\n  ref: v0.59.0\n' >"$fixture/pin.yml"
cp "$fixture/pin.yml" "$fixture/pin-before.yml"
"$assets/skills-sync-preflight.sh" --lag-only "$fixture/pin.yml" >"$fixture/out"
cmp "$fixture/pin-before.yml" "$fixture/pin.yml"
# Real Task preserves semantic exits and overrides the template's group output.
# Explicit CI flags exercise its stdout annotations on developer machines too.
mkdir "$fixture/grouped"
cat >"$fixture/grouped/Taskfile.yml" <<'YAML'
version: '3'
output:
  group:
    begin: '::group::{{.TASK}}'
    end: '::endgroup::'
tasks:
  skills:status:
    cmds:
      - |
        printf '%s\n' "$TASK_STATE_LINE"
        exit "$TASK_STATUS_EXIT"
YAML
for kind in behind current; do
    if [[ $kind == behind ]]; then
        line='state=upstream-newer pinned=v0.59.0 vendored=v0.59.0 latest=v0.60.0'
        code=12
        expected='behind v0.60.0'
    else
        line='state=in-sync pinned=v0.60.0 vendored=v0.60.0 latest=v0.60.0'
        code=0
        expected=current
    fi
    (cd "$fixture/grouped" && CI=true GITHUB_ACTIONS=true STATUS_REAL_TASK="$real_task" TASK_STATE_LINE="$line" TASK_STATUS_EXIT="$code" "$assets/skills-sync-preflight.sh" --lag-only) >"$fixture/out"
    python3 - "$fixture/out" "$expected" <<'PYTEST'
import json, sys
assert json.loads(open(sys.argv[1]).read())['pin_lag'] == sys.argv[2]
PYTEST
done
# Exercise the real status implementation, including its supported padded tags.
# Status reads managed provenance; this fixture does not need to vendor assets.
status_script="$(git -C "$assets" rev-parse --show-toplevel)/scripts/sync-skills.sh"
mkdir -p "$fixture/releases" "$fixture/real-status/vendored/skills"
git -C "$fixture/releases" init -q
git -C "$fixture/releases" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm release
git -C "$fixture/releases" tag v1.2.3
git -C "$fixture/releases" tag v01.2.4
cat >"$fixture/real-status/Taskfile.yml" <<'YAML'
version: '3'
output:
  group:
    begin: '::group::{{.TASK}}'
    end: '::endgroup::'
tasks:
  skills:status:
    cmds:
      - bash "$STATUS_SCRIPT" status {{.CLI_ARGS}}
YAML
# Run the actual documented snippet, so reverting to a bare status command
# reproduces the bash -eu abort rather than passing a separate adapter test.
python3 - "$assets/../SKILL.md" "$fixture/in-sync-step.sh" <<'PYTEST'
import pathlib, re, sys, textwrap
text = pathlib.Path(sys.argv[1]).read_text()
step = text.split('3. **In sync.**', 1)[1].split('\nVendored skills and agents', 1)[0]
snippet = re.search(r'```bash\n(.*?)\n\s*```', step, re.S)
assert snippet is not None
pathlib.Path(sys.argv[2]).write_text(textwrap.dedent(snippet.group(1)) + '\n')
PYTEST
ln -s "$assets" "$fixture/real-status/assets"
for kind in behind current unknown; do
    pin=v1.2.3
    upstream="$fixture/releases"
    latest=v01.2.4
    state=upstream-newer
    code=12
    expected='behind v01.2.4'
    if [[ $kind == current ]]; then
        pin=v01.2.4
        state=in-sync
        code=0
        expected=current
    elif [[ $kind == unknown ]]; then
        upstream="$fixture/unavailable-upstream"
        latest=unknown
        state=in-sync
        code=0
        expected=unknown
    fi
    cat >"$fixture/real-status/.skills-sync.yaml" <<YAML
source:
  repo: "$upstream"
  ref: $pin
dest: vendored/skills
YAML
    printf '# ref: %s\n# managed:\n' "$pin" >"$fixture/real-status/vendored/skills/.SKILLS_PROVENANCE"
    actual=0
    (cd "$fixture/real-status" && CI=true GITHUB_ACTIONS=true STATUS_SCRIPT="$status_script" "$real_task" --silent --exit-code --output interleaved skills:status) \
        >"$fixture/status-out" || actual=$?
    [[ $actual == "$code" ]]
    python3 - "$fixture/status-out" "state=$state pinned=$pin vendored=$pin latest=$latest" "$code" <<'PYTEST'
import sys
lines = open(sys.argv[1]).read().splitlines()
assert [line for line in lines if not line.startswith('::')] == [sys.argv[2]]
if sys.argv[3] == '12':
    assert any(line.startswith('::error ') for line in lines), lines
PYTEST
    (cd "$fixture/real-status" && CI=true GITHUB_ACTIONS=true STATUS_REAL_TASK="$real_task" STATUS_SCRIPT="$status_script" \
        bash -eu -c '. "$1"; echo continued' _ "$fixture/in-sync-step.sh") >"$fixture/out"
    python3 - "$fixture/out" "$pin" "$latest" "$expected" <<'PYTEST'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert len(lines) == 2 and lines[1] == 'continued'
assert json.loads(lines[0]) == dict(pin=sys.argv[2], latest=sys.argv[3], pin_lag=sys.argv[4])
PYTEST
done
# A missing status runner is also unknown.
rm "$fixture/bin/task"
mkdir "$fixture/no-task"
ln -s "$(command -v python3)" "$fixture/no-task/python3"
ln -s "$(command -v dirname)" "$fixture/no-task/dirname"
PATH="$fixture/no-task" /bin/bash "$assets/skills-sync-preflight.sh" --lag-only >"$fixture/out"
python3 - "$fixture/out" <<'PYTEST'
import json, sys
assert json.loads(open(sys.argv[1]).read())['pin_lag'] == 'unknown'
PYTEST
printf 'skills sync preflight tests passed\n'
