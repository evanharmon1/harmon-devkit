#!/usr/bin/env bash
# Regression tests for the audit's deliberately limited OWNED evaluator.
set -euo pipefail
repo="$(git rev-parse --show-toplevel)"
assets="$repo/ai/skills/repo/standardize-repo/assets"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { # shell-robustness: ok — the test reporter terminates this process
    echo "FAIL: $*" >&2
    exit 1
}
source="$tmp/template"
target="$tmp/target"
mkdir -p "$source/template/docs/nested" "$target/docs/nested"
git init -q "$source"
git -C "$source" config user.name Fixture
git -C "$source" config user.email fixture@example.invalid
for path in docs/direct.txt docs/nested/deep.txt repo-owned.txt; do
    printf 'template\n' >"$source/template/$path"
    printf 'local\n' >"$target/$path"
done

audit() {
    git -C "$source" add -A
    git -C "$source" commit -qm 'test: ownership declaration'
    printf '_commit: %s\n' "$(git -C "$source" rev-parse HEAD)" >"$target/.copier-answers.yml"
    audit_rc=0
    audit_out="$(HARMON_INIT="$source" bash "$assets/diff-template.sh" "$target" 2>&1)" || audit_rc=$?
}
refused() {
    audit
    [ "$audit_rc" -eq 2 ] || fail "$1 returned $audit_rc: $audit_out"
    grep -Fq "$1" <<<"$audit_out" || fail "missing deliberate-limit diagnostic: $audit_out"
    if grep -Eq '^(OWNED|DRIFT|MISSING) ' <<<"$audit_out"; then
        fail 'unsupported config emitted a partial audit'
    fi
}

cat >"$source/copier.yml" <<'YAML'
_subdirectory: template
_skip_if_exists: [repo-owned.txt]
---
_skip_if_exists: ["docs/**"]
YAML
refused 'multi-document copier config is not supported'

# A top-level include used to read as an absent key and silently take the
# legacy path. Copier really loads this config (the audit renders it first).
printf '!include included.yml\n' >"$source/copier.yml"
printf '_subdirectory: template\n_skip_if_exists: ["docs/**", repo-owned.txt]\n' >"$source/included.yml"
refused '!include copier config is not supported'

# Includes in a single-document list are another valid Copier merge shape.
cat >"$source/copier.yml" <<'YAML'
- _subdirectory: template
- !include included.yml
YAML
refused '!include copier config is not supported'

cat >"$source/copier.yml" <<'YAML'
_subdirectory: template
_skip_if_exists: ["docs/**/", repo-owned.txt]
YAML
refused "pattern ending in '/**/' is not supported"

# Positive control: a supported glob covers direct AND deeper files and a
# literal still receives OWNED.
cat >"$source/copier.yml" <<'YAML'
_subdirectory: template
_skip_if_exists: ["docs/**", repo-owned.txt]
YAML
audit
[ "$audit_rc" -eq 0 ] || fail "supported declaration returned $audit_rc: $audit_out"
for path in docs/direct.txt docs/nested/deep.txt repo-owned.txt; do
    grep -Fq "OWNED    $path " <<<"$audit_out" || fail "supported path not OWNED: $path"
done

# The opposite control keeps non-matching content gating rather than hiding it.
printf '_subdirectory: template\n_skip_if_exists: [repo-owned.txt]\n' >"$source/copier.yml"
audit
[ "$audit_rc" -eq 1 ] || fail "unowned drift returned $audit_rc: $audit_out"
grep -Fq 'DRIFT    docs/direct.txt' <<<"$audit_out" || fail 'unowned direct child did not gate'
echo 'PASS: OWNED loader/matcher limits refuse explicitly and supported declarations preserve classification'
