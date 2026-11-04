#!/usr/bin/env bash
# Offline create-only contract: no label edits, deletes or forced creates.
set -euo pipefail
asset="$(cd "$(dirname "$0")" && pwd)/ensure-missing-labels.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/target/scripts"
cat >"$fixture/target/scripts/label-registry-render.mjs" <<'RENDERER'
import fs from 'node:fs'
if (process.argv[2] !== 'labels') process.exit(3)
if (fs.existsSync(new URL('../expect-profiles', import.meta.url)) &&
    JSON.stringify(process.argv.slice(2)) !== JSON.stringify(['labels', '--foreman', '--release-please'])) process.exit(4)
process.stdout.write(fs.readFileSync(new URL('../labels.txt', import.meta.url), 'utf8'))
RENDERER
printf 'model:sol|006B75|Model Sol\nmodel-version:6.1|006B75|Version | 6.1\n' >"$fixture/target/labels.txt"
cat >"$fixture/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"$root/calls"
[ "$1" = label ] || exit 91
command="$2"
shift 2
case "$command" in
list)
    test "$*" = '--repo example/repo --limit 10000 --json name,color,description'
    cat "$root/live.json"
    ;;
create)
    name="$1"
    shift
    test "$1" = --repo && test "$2" = example/repo
    test "$3" = --color && test "$4" = 006B75
    test "$5" = --description && test "$#" -eq 6
    [ ! -f "$root/fail-create" ] || exit 7
    jq --arg name "$name" --arg color "$4" --arg description "$6" \
        '. + [{name:$name,color:$color,description:$description}]' "$root/live.json" >"$root/next"
    mv "$root/next" "$root/live.json"
    ;;
*) exit 92 ;;
esac
GH_STUB
chmod +x "$fixture/gh"
reset_live() {
    printf '[{"name":"Model:Sol","color":"ffffff","description":"Keep custom metadata"}]\n' >"$fixture/live.json"
    cp "$fixture/live.json" "$fixture/before.json"
    : >"$fixture/calls"
}
run() {
    if bash "$asset" --repo example/repo --checkout "$fixture/target" --gh-bin "$fixture/gh" "$@" >"$fixture/result" 2>"$fixture/error"; then
        status=0
    else
        status=$?
    fi
    jq -e 'has("created") and has("already_present") and has("refused")' "$fixture/result" >/dev/null
}
reset_live
run
[ "$status" -eq 0 ]
jq -e '.created == ["model-version:6.1"] and .already_present == ["model:sol"] and .refused == []' "$fixture/result" >/dev/null
# Compare exact serialized bytes of the existing object, including metadata.
jq -c '.[0]' "$fixture/before.json" >"$fixture/existing-before"
jq -c '.[0]' "$fixture/live.json" >"$fixture/existing-after"
cmp "$fixture/existing-before" "$fixture/existing-after"
! grep -E 'label (edit|delete)|--force|label create model:sol' "$fixture/calls" || exit 1
grep -F 'label create model-version:6.1 --repo example/repo --color 006B75 --description Version | 6.1' "$fixture/calls" >/dev/null
# Second run makes no mutation and preserves the entire snapshot byte-for-byte.
cp "$fixture/live.json" "$fixture/before.json"
: >"$fixture/calls"
run
[ "$status" -eq 0 ]
cmp "$fixture/before.json" "$fixture/live.json"
! grep -F 'label create' "$fixture/calls" || exit 1
reset_live
run --dry-run
[ "$status" -eq 0 ]
jq -e '.created == [] and .would_create == ["model-version:6.1"]' "$fixture/result" >/dev/null
cmp "$fixture/before.json" "$fixture/live.json"
! grep -F 'label create' "$fixture/calls" || exit 1
# Both optional profiles must be forwarded after the labels mode argument.
touch "$fixture/target/expect-profiles"
run --dry-run --foreman --release-please
[ "$status" -eq 0 ]
jq -e '.created == [] and .would_create == ["model-version:6.1"]' "$fixture/result" >/dev/null
cmp "$fixture/before.json" "$fixture/live.json"
! grep -F 'label create' "$fixture/calls" || exit 1
rm "$fixture/target/expect-profiles"
# An exactly-full bounded listing may hide another page; it must refuse.
jq -n '[range(10000) | {name:("existing:" + tostring),color:"123456",description:""}]' >"$fixture/live.json"
: >"$fixture/calls"
run
[ "$status" -eq 1 ]
jq -e '.created == [] and (.refused[0].reason | contains("truncated"))' "$fixture/result" >/dev/null
! grep -F 'label create' "$fixture/calls" || exit 1
reset_live
mv "$fixture/target/scripts/label-registry-render.mjs" "$fixture/renderer"
run
[ "$status" -eq 1 ]
[ ! -s "$fixture/calls" ]
jq -e '.refused[0].reason | contains("missing target")' "$fixture/result" >/dev/null
mv "$fixture/renderer" "$fixture/target/scripts/label-registry-render.mjs"
# A renderer failure or malformed API response must also refuse before writes.
mv "$fixture/target/labels.txt" "$fixture/valid-labels"
run
[ "$status" -eq 1 ]
[ ! -s "$fixture/calls" ]
jq -e '.refused[0].reason | contains("renderer failed")' "$fixture/result" >/dev/null
mv "$fixture/valid-labels" "$fixture/target/labels.txt"
printf '{"partial":true}\n' >"$fixture/live.json"
run
[ "$status" -eq 1 ]
! grep -F 'label create' "$fixture/calls" || exit 1
reset_live
# Invalid renderer records must not be silently dropped before writes.
printf 'bad record\n' >>"$fixture/target/labels.txt"
run
[ "$status" -eq 1 ]
[ ! -s "$fixture/calls" ]
sed '$d' "$fixture/target/labels.txt" >"$fixture/valid-labels"
mv "$fixture/valid-labels" "$fixture/target/labels.txt"
touch "$fixture/fail-create"
run
[ "$status" -eq 1 ]
jq -e '.created == [] and .refused[0].name == "model-version:6.1"' "$fixture/result" >/dev/null
cmp "$fixture/before.json" "$fixture/live.json"
# A partial create failure retains the successful prefix in its JSON report.
rm "$fixture/fail-create"
printf 'feature:new|006B75|A new label\n' >"$fixture/target/labels.txt"
printf 'model-version:6.1|006B75|Version | 6.1\n' >>"$fixture/target/labels.txt"
# Make the stub fail only the second create; no rollback or edit is permitted.
sed 's/\[ ! -f "$root\/fail-create" \] || exit 7/[ "$name" != model-version:6.1 ] || exit 7/' \
    "$fixture/gh" >"$fixture/gh-partial"
mv "$fixture/gh-partial" "$fixture/gh"
chmod +x "$fixture/gh"
run
[ "$status" -eq 1 ]
jq -e '.created == ["feature:new"] and .refused[0].name == "model-version:6.1"' "$fixture/result" >/dev/null
! grep -E 'label (edit|delete)|--force' "$fixture/calls" || exit 1
printf 'ensure-missing-labels: all offline tests passed\n'
