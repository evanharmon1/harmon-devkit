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
printf 'source: {}\n' >"$fixture/pin.yml"
check '{"verdict":"unknown","reason":"malformed-pin"}' 2
printf 'source:\n  ref: v0.58\n' >"$fixture/pin.yml"
check '{"verdict":"unknown","reason":"malformed-pin"}' 2
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
for doc in "$(dirname "$asset")/../references/mode-update.md" "$(dirname "$asset")/../references/mode-adopt-existing.md"; do
    block="$(sed -n '/^case "\$PIN_STATUS" in$/,/^esac$/p' "$doc")"
    for status in 0 1 2 3; do
        if (PIN_STATUS="$status" PIN_CHECK='{"reason":"test"}' eval "$block" >/dev/null 2>&1); then result=0; else result=$?; fi
        case "$status" in 0 | 2) test "$result" -eq 0 ;; *) test "$result" -ne 0 ;; esac
    done
done
printf 'pin minimum tests passed\n'
