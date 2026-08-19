#!/usr/bin/env bash
# Offline behavioral tests for the portable claim identity resolver.
set -euo pipefail
cd "$(dirname "$0")/.."

resolver="ai/skills/universal/claim/assets/resolve-claim-label.sh"
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
available="$tmp/available"
issue="$tmp/issue"
printf '%s\n' claim:claude claim:gpt claim:gpt:sol claim:gpt:terra agent:claude-code agent:codex agent:gemini-cli agent:kimi-k2 agent:qwen-code >"$available"

run() {
    "$resolver" --registry agent-registry.json --project-management github --available-labels "$available" --issue-labels "$issue" "$@"
}

printf '%s\n' >"$issue"
out="$(run --harness claude-code --runtime-family claude)" || fail "Claude resolution failed"
printf '%s\n' "$out" | grep -Fx 'family=claude' >/dev/null || fail "Claude family was not selected"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:claude' >/dev/null || fail "Claude claim label was not selected"

out="$(run --harness codex-cli --runtime-family gpt)" || fail "Codex resolution failed"
printf '%s\n' "$out" | grep -Fx 'family=gpt' >/dev/null || fail "Codex must resolve to GPT"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt' >/dev/null || fail "Codex must select claim:gpt"

out="$(run --harness codex-cli --runtime-family gpt --claim-model terra)" || fail "trusted model-pinned Codex claim failed"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt:terra' >/dev/null || fail "trusted model pin was not selected"

printf '%s\n' claim:gpt:terra >"$issue"
if run --harness codex-cli --runtime-family gpt --claim-model sol >"$tmp/out" 2>&1; then fail "different model claim must not be idempotent"; else status=$?; fi
[ "$status" = 10 ] || fail "different model claim exited $status, want 10"
grep -Fx 'conflict_label=claim:gpt:terra' "$tmp/out" >/dev/null || fail "different model claim was not reported as a conflict"

printf '%s\n' claim:gpt >"$tmp/family-only-available"
if run --harness codex-cli --runtime-family gpt --claim-model sol --available-labels "$tmp/family-only-available" >/dev/null 2>&1; then fail "missing requested model label must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "missing requested model label exited $status, want 20"

if run --harness codex-cli --runtime-family gpt --claim-model opus >/dev/null 2>&1; then fail "foreign trusted model must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "foreign trusted model exited $status, want 20"

printf '%s\n' claim:gpt:terra >"$issue"
out="$(run --harness codex-cli --runtime-family gpt)" || fail "same-family model claim must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=claim:gpt:terra' >/dev/null || fail "same-family claim was not recognized"

printf '%s\n' claim:claude >"$issue"
if run --harness codex-cli --runtime-family gpt >"$tmp/out" 2>&1; then fail "different-family claim must block"; else status=$?; fi
[ "$status" = 10 ] || fail "different-family claim exited $status, want 10"
grep -Fx 'conflict_label=claim:claude' "$tmp/out" >/dev/null || fail "conflict label was not reported"
grep -Fx 'existing_label=' "$tmp/out" >/dev/null || fail "foreign-only conflict must report no existing marker"

printf '%s\n' claim:claude agent:claude-code >"$issue"
if run --harness codex-cli --runtime-family gpt >"$tmp/out" 2>&1; then fail "all foreign markers must block"; else status=$?; fi
[ "$status" = 11 ] || fail "multiple foreign markers exited $status, want 11"
[ "$(grep -c '^conflict_label=' "$tmp/out")" = 2 ] || fail "resolver did not report every foreign marker"
grep -Fx 'takeover=refused' "$tmp/out" >/dev/null || fail "multi-marker takeover was not refused"
grep -Fx 'conflict_label=claim:claude' "$tmp/out" >/dev/null || fail "modern conflict was lost"
grep -Fx 'conflict_label=agent:claude-code' "$tmp/out" >/dev/null || fail "legacy conflict was lost"

printf '%s\n' claim:gpt claim:claude >"$issue"
if run --harness codex-cli --runtime-family gpt >"$tmp/out" 2>&1; then fail "mixed ownership must block"; else status=$?; fi
[ "$status" = 10 ] || fail "mixed ownership exited $status, want 10"
grep -Fx 'existing_label=claim:gpt' "$tmp/out" >/dev/null || fail "mixed ownership omitted its existing marker"

printf '%s\n' >"$issue"
if run --harness claude-code --runtime-family gpt >/dev/null 2>&1; then fail "fixed harness mismatch must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "fixed harness mismatch exited $status, want 20"

if run --harness codex-cli >/dev/null 2>&1; then fail "fixed harness without host-attested family must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "fixed harness missing family exited $status, want 20"

if run --harness opencode >/dev/null 2>&1; then fail "broker without runtime family must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "broker ambiguity exited $status, want 20"
out="$(run --harness opencode --runtime-family gpt)" || fail "broker with trusted runtime family failed"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt' >/dev/null || fail "broker selected wrong target"

printf '%s\n' agent:codex >"$issue"
out="$(run --harness codex-cli --runtime-family gpt)" || fail "registry-declared Codex legacy marker must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:codex' >/dev/null || fail "Codex legacy marker was not recognized"

printf '%s\n' agent:gemini-cli >"$issue"
out="$(run --harness antigravity --runtime-family gemini)" || fail "Gemini legacy marker must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:gemini-cli' >/dev/null || fail "Gemini legacy marker was not recognized"

printf '%s\n' agent:kimi-k2 >"$issue"
out="$(run --harness claude-code-kimi --runtime-family kimi)" || fail "Kimi legacy marker must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:kimi-k2' >/dev/null || fail "Kimi legacy marker was not recognized"

printf '%s\n' agent:qwen-code >"$issue"
out="$(run --harness qwen-code --runtime-family qwen)" || fail "Qwen legacy marker must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:qwen-code' >/dev/null || fail "Qwen legacy marker was not recognized"

printf '%s\n' agent:claude-code >"$issue"
if run --harness codex-cli --runtime-family gpt >/dev/null 2>&1; then fail "foreign legacy marker must block"; else status=$?; fi
[ "$status" = 10 ] || fail "foreign legacy marker exited $status, want 10"

printf '%s\n' agent:codex >"$tmp/legacy-available"
printf '%s\n' >"$issue"
out="$("$resolver" --registry agent-registry.json --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/legacy-available" --issue-labels "$issue")" || fail "registry-declared legacy fallback failed"
printf '%s\n' "$out" | grep -Fx 'target_label=agent:codex' >/dev/null || fail "legacy fallback selected the wrong label"

jq '(.families[] | select(.slug == "gpt")) |= del(.legacy_claim_labels)' \
    agent-registry.json >"$tmp/pre-migration-registry.json"
if "$resolver" --registry "$tmp/pre-migration-registry.json" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/legacy-available" --issue-labels "$issue" >/dev/null 2>&1; then fail "undeclared legacy aliases must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "undeclared legacy aliases exited $status, want 20"

printf '%s\n' claim:gpt:terra >"$tmp/model-only-available"
printf '%s\n' claim:gpt:terra >"$issue"
out="$("$resolver" --registry agent-registry.json --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/model-only-available" --issue-labels "$issue")" || fail "existing model claim must not require a family label"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt:terra' >/dev/null || fail "existing model claim was not retained"

: >"$issue"
if "$resolver" --harness codex-cli --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then fail "registry-less fixed harness without family must fail"; else status=$?; fi
[ "$status" = 20 ] || fail "registry-less missing family exited $status, want 20"
out="$("$resolver" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$available" --issue-labels "$issue")" || fail "registry-less trusted family failed"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt' >/dev/null || fail "registry-less trusted family selected wrong target"

jq '(.families[] | select(.slug == "gpt")).legacy_claim_labels = []' \
    agent-registry.json >"$tmp/no-legacy-registry.json"
if "$resolver" --registry "$tmp/no-legacy-registry.json" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/legacy-available" --issue-labels "$issue" >/dev/null 2>&1; then fail "explicit empty aliases must disable fallback"; else status=$?; fi
[ "$status" = 20 ] || fail "explicit empty aliases exited $status, want 20"

printf '%s\n' agent:codex >"$issue"
out="$(run --harness opencode --runtime-family gpt)" || fail "same-family broker must recognize family-owned legacy alias"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:codex' >/dev/null || fail "broker misclassified its family legacy alias"

jq '(.families[] | select(.slug == "gpt")).legacy_claim_labels = ["not-a-label"]' \
    agent-registry.json >"$tmp/malformed-alias-registry.json"
if "$resolver" --registry "$tmp/malformed-alias-registry.json" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then fail "malformed registry alias must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "malformed registry alias exited $status, want 20"

jq '(.families[] | select(.slug == "claude")).legacy_claim_labels = ["agent:shared"] | (.families[] | select(.slug == "gpt")).legacy_claim_labels = ["agent:shared"]' \
    agent-registry.json >"$tmp/ambiguous-alias-registry.json"
if "$resolver" --registry "$tmp/ambiguous-alias-registry.json" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then fail "duplicate legacy aliases must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "duplicate legacy aliases exited $status, want 20"

echo "==> label-less project modes retain the assignee/comment fallback"
: >"$available"
: >"$issue"
for project_management in none linear; do
    out="$("$resolver" --registry agent-registry.json --harness codex-cli \
        --runtime-family gpt --project-management "$project_management" \
        --available-labels "$available" --issue-labels "$issue")" ||
        fail "project_management=$project_management label-less fallback failed"
    printf '%s\n' "$out" | grep -Fx 'family=gpt' >/dev/null ||
        fail "project_management=$project_management lost the acting family"
    printf '%s\n' "$out" | grep -Fx 'target_label=n/a' >/dev/null ||
        fail "project_management=$project_management did not select the n/a fallback"
    printf '%s\n' "$out" | grep -Fx 'existing_label=' >/dev/null ||
        fail "project_management=$project_management reported an existing marker"
done
if "$resolver" --registry agent-registry.json --harness codex-cli \
    --runtime-family gpt --project-management github \
    --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then
    fail "project_management=github without ownership labels must fail closed"
else
    status=$?
fi
[ "$status" = 20 ] || fail "label-less github mode exited $status, want 20"
if "$resolver" --registry agent-registry.json --harness codex-cli \
    --runtime-family gpt --project-management unknown \
    --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then
    fail "an unknown project mode must fail closed"
else
    status=$?
fi
[ "$status" = 20 ] || fail "unknown project mode exited $status, want 20"

grep -F 'if ! gh label list' ai/skills/universal/claim/SKILL.md >/dev/null || fail "label vocabulary read must fail closed"
grep -F 'if ! gh issue view' ai/skills/universal/claim/SKILL.md >/dev/null || fail "issue-label read must fail closed"
grep -F -- '--project-management "$project_management"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must pass the trusted project mode"
if grep -Eq 'claim:(claude|gpt)|agent:(claude-code|codex)' \
    ai/skills/universal/track-work/references/claim-lifecycle.md; then
    fail "canonical claim lifecycle examples must use portable family placeholders"
fi

echo 'PASS: portable claim family resolution'
