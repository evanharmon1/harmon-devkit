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
check '{"verdict":"unknown"}' 2
printf 'source:\n  ref: v0.58\n' >"$fixture/pin.yml"
check '{"verdict":"unknown"}' 2
printf 'source:\n  ref: v0.58.0\n' >"$fixture/pin.yml"
printf 'other: value\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'missing minimum'
check '{"verdict":"unknown"}' 2
printf '_min_harmon_devkit_skills: "v0.58"\n' >"$fixture/template/copier.yml"
git -C "$fixture/template" add copier.yml
git -C "$fixture/template" commit -qm 'malformed minimum'
check '{"verdict":"unknown"}' 2
printf 'pin minimum tests passed\n'
