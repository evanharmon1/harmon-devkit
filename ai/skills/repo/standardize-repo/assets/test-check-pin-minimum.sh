#!/usr/bin/env bash
set -euo pipefail
asset="$(cd "$(dirname "$0")" && pwd)/check-pin-minimum.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/template"
git -C "$fixture/template" init -q
git -C "$fixture/template" config user.name Test
git -C "$fixture/template" config user.email test@example.invalid
printf '_min_harmon_devkit_skills: "v0.58.0"\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm fixture
check() {
    local expected="$1" code="$2" actual status
    if actual="$("$asset" "$fixture/template" HEAD "$fixture/pin.yml")"; then status=0; else status=$?; fi
    test "$status" -eq "$code"
    test "$actual" = "$expected"
}
printf 'source:\n  ref: v0.59.0\n' >"$fixture/pin.yml"
check '{"verdict":"ok","pin":"v0.59.0","minimum":"v0.58.0"}' 0
printf 'source:\n  ref: v0.58.0\n' >"$fixture/pin.yml"
check '{"verdict":"ok","pin":"v0.58.0","minimum":"v0.58.0"}' 0
printf 'source:\n  ref: v0.9.0\n' >"$fixture/pin.yml"
check '{"verdict":"below-minimum","pin":"v0.9.0","minimum":"v0.58.0"}' 1
printf 'defaults: &d {ref: v0.1.0}\nsource: {<<: *d}\n' >"$fixture/pin.yml"
check '{"verdict":"below-minimum","pin":"v0.1.0","minimum":"v0.58.0"}' 1
printf 'defaults: &d {ref: v0.59.0}\nsource: {<<: *d}\n' >"$fixture/pin.yml"
check '{"verdict":"ok","pin":"v0.59.0","minimum":"v0.58.0"}' 0
printf 'source: {ref: v0.59.0}\n---\nsource: {ref: v0.1.0}\n' >"$fixture/pin.yml"
check '{"verdict":"unknown","reason":"read-error"}' 2
printf 'source: {}\n' >"$fixture/pin.yml"
check '{"verdict":"unknown","reason":"malformed-pin"}' 2
printf 'source:\n  ref: v0.58\n' >"$fixture/pin.yml"
check '{"verdict":"unknown","reason":"malformed-pin"}' 2
printf 'source:\n  ref: v0.58.0\n' >"$fixture/pin.yml"
printf 'base: &b {_min_harmon_devkit_skills: "v0.58.0"}\n<<: *b\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'merged minimum'
printf 'source:\n  ref: v0.1.0\n' >"$fixture/pin.yml"
check '{"verdict":"below-minimum","pin":"v0.1.0","minimum":"v0.58.0"}' 1
printf 'source:\n  ref: v0.59.0\n' >"$fixture/pin.yml"
check '{"verdict":"ok","pin":"v0.59.0","minimum":"v0.58.0"}' 0
printf 'source:\n  ref: v0.58.0\n' >"$fixture/pin.yml"
printf 'other: value\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'missing minimum'
check '{"verdict":"unknown","reason":"no-declared-minimum"}' 2
printf '_min_harmon_devkit_skills: "v0.58"\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'malformed minimum'
check '{"verdict":"unknown","reason":"malformed-minimum"}' 2
printf '_min_harmon_devkit_skills: "v0.58.0"\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'restore minimum'
rm "$fixture/pin.yml"
check '{"verdict":"unknown","reason":"no-skills-manifest"}' 2
printf 'source: [invalid\n' >"$fixture/pin.yml"
check '{"verdict":"unknown","reason":"read-error"}' 2
for pair in 'v0.9.0 v0.59.0' 'v0.59.0 v0.9.0'; do
    read -r first second <<<"$pair"
    printf 'source:\n  ref: %s\n  ref: %s\n' "$first" "$second" >"$fixture/pin.yml"
    check '{"verdict":"unknown","reason":"duplicate-key"}' 2
    printf 'source:\n  ref: %s\nsource:\n  ref: %s\n' "$first" "$second" >"$fixture/pin.yml"
    check '{"verdict":"unknown","reason":"duplicate-key"}' 2
    printf 'source:\n  ref: v0.58.0\n' >"$fixture/pin.yml"
    printf '_min_harmon_devkit_skills: "%s"\n_min_harmon_devkit_skills: "%s"\n' "$first" "$second" >"$fixture/template/copier.yml"
    git -C "$fixture/template" add copier.yml
    git -C "$fixture/template" commit -qm 'duplicate minimum'
    check '{"verdict":"unknown","reason":"duplicate-key"}' 2
done
# Restore a valid minimum for the unavailable-yq cases.
printf '_min_harmon_devkit_skills: "v0.58.0"\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'restore valid minimum'
# Keep Bash, Python and Git available while excluding yq from PATH.
mkdir "$fixture/no-yq"
ln -s "$(command -v bash)" "$fixture/no-yq/bash"
ln -s "$(command -v python3)" "$fixture/no-yq/python3"
ln -s "$(command -v git)" "$fixture/no-yq/git"
for pin in v0.1.0 v0.59.0 missing; do
    if [[ "$pin" == missing ]]; then rm -f "$fixture/pin.yml"; else
        printf 'source:\n  ref: %s\n' "$pin" >"$fixture/pin.yml"
    fi
    if actual="$(PATH="$fixture/no-yq" "$asset" "$fixture/template" HEAD "$fixture/pin.yml" 2>"$fixture/error")"; then status=0; else status=$?; fi
    test "$status" -eq 3
    test "$actual" = '{"verdict":"error","reason":"yq-unavailable"}'
    test -s "$fixture/error"
done
# A yq that passes the probe but fails on input reports a read error.
cat >"$fixture/no-yq/yq" <<'YQ'
#!/bin/sh
if [ "$1" = --version ]; then
    printf 'yq (https://github.com/mikefarah/yq/) version v4.1.0\n'
else
    exit 1
fi
YQ
chmod +x "$fixture/no-yq/yq"
if actual="$(PATH="$fixture/no-yq" "$asset" "$fixture/template" HEAD "$fixture/pin.yml" 2>"$fixture/error")"; then status=0; else status=$?; fi
test "$status" -eq 2
test "$actual" = '{"verdict":"unknown","reason":"read-error"}'
for doc in "$(dirname "$asset")/../references/mode-update.md" "$(dirname "$asset")/../references/mode-adopt-existing.md"; do
    block="$(sed -n '/^case "\$PIN_STATUS" in$/,/^esac$/p' "$doc")"
    for status in 0 1 2 3; do
        if (PIN_STATUS="$status" PIN_CHECK='{"reason":"test"}' eval "$block" >/dev/null 2>&1); then result=0; else result=$?; fi
        case "$status" in 0 | 2) test "$result" -eq 0 ;; *) test "$result" -ne 0 ;; esac
    done
    for input in '{"reason":"test"}' '{}' '{"reason":""}'; do
        case "$input" in *test*) expected=test ;; *) expected=unspecified ;; esac
        output="$(PATH=/nonexistent PIN_STATUS=2 PIN_CHECK="$input" eval "$block")"
        test "$output" = "skills pin compatibility unknown: $expected"
    done
done
printf 'pin minimum tests passed\n'
