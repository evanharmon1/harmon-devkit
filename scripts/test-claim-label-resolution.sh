#!/usr/bin/env bash
# Offline behavioral tests for the portable claim identity resolver.
set -euo pipefail
cd "$(dirname "$0")/.."

resolver="ai/skills/universal/claim/assets/resolve-claim-label.sh"
runtime_resolver="ai/skills/universal/claim/assets/resolve-runtime-environment.sh"
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

printf '%s\n' claim:gpt >"$issue"
out="$(run --harness codex-cli --runtime-family gpt --claim-model terra)" || fail "trusted model-pinned Codex claim failed"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt:terra' >/dev/null || fail "trusted model pin was not selected"
printf '%s\n' "$out" | grep -Fx 'existing_label=' >/dev/null || fail "family marker must not suppress the model-label write"

printf '%s\n' agent:codex >"$issue"
out="$(run --harness codex-cli --runtime-family gpt --claim-model terra)" || fail "legacy family marker must permit model refinement"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt:terra' >/dev/null || fail "legacy family marker selected the wrong model refinement"
printf '%s\n' "$out" | grep -Fx 'existing_label=' >/dev/null || fail "legacy family marker must coexist with the model-label write"

: >"$issue"
if run --harness codex-cli --runtime-family gpt --claim-model terra >/dev/null 2>&1; then fail "model pin without its family marker must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "model pin without family marker exited $status, want 20"

printf '%s\n' claim:gpt claim:gpt:terra >"$issue"
if run --harness codex-cli --runtime-family gpt --claim-model sol >"$tmp/out" 2>&1; then fail "different model claim must not be idempotent"; else status=$?; fi
[ "$status" = 10 ] || fail "different model claim exited $status, want 10"
grep -Fx 'conflict_label=claim:gpt:terra' "$tmp/out" >/dev/null || fail "different model claim was not reported as a conflict"
if grep -Fx 'conflict_label=claim:gpt' "$tmp/out" >/dev/null; then fail "required family marker must not become a takeover conflict"; fi

printf '%s\n' claim:gpt >"$tmp/family-only-available"
if run --harness codex-cli --runtime-family gpt --claim-model sol --available-labels "$tmp/family-only-available" >/dev/null 2>&1; then fail "missing requested model label must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "missing requested model label exited $status, want 20"

if run --harness codex-cli --runtime-family gpt --claim-model opus >/dev/null 2>&1; then fail "foreign trusted model must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "foreign trusted model exited $status, want 20"

printf '%s\n' claim:gpt claim:gpt:terra >"$issue"
out="$(run --harness codex-cli --runtime-family gpt)" || fail "same-family model claim must be idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=claim:gpt' >/dev/null || fail "same-family base marker was not recognized"
printf '%s\n' "$out" | grep -Fx 'model_label=claim:gpt:terra' >/dev/null || fail "same-family model refinement was not preserved"

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
out="$("$resolver" --registry "$tmp/pre-migration-registry.json" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/legacy-available" --issue-labels "$issue")" || fail "pre-field registry legacy fallback failed"
printf '%s\n' "$out" | grep -Fx 'target_label=agent:codex' >/dev/null || fail "pre-field registry selected the wrong legacy fallback"

printf '%s\n' claim:gpt:terra >"$tmp/model-only-available"
printf '%s\n' claim:gpt:terra >"$issue"
out="$("$resolver" --registry agent-registry.json --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/model-only-available" --issue-labels "$issue")" || fail "existing model claim must not require a family label"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt:terra' >/dev/null || fail "existing model claim was not retained"

printf '%s\n' claim:gpt claim:gpt:terra >"$issue"
out="$("$resolver" --registry agent-registry.json --harness codex-cli --runtime-family gpt --project-management github --available-labels "$available" --issue-labels "$issue")" ||
    fail "coexisting family and model markers must produce a usable family-level plan"
printf '%s\n' "$out" | grep -Fx 'family_label=claim:gpt' >/dev/null ||
    fail "family-level plan must retain the base family marker"
printf '%s\n' "$out" | grep -Fx 'model_label=claim:gpt:terra' >/dev/null ||
    fail "family-level plan must report the coexisting model refinement"

printf '%s\n' claim:gpt claim:gpt:terra claim:gpt:sol >"$issue"
if "$resolver" --registry agent-registry.json --harness codex-cli --runtime-family gpt \
    --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then
    fail "multiple model refinements must not collapse into an order-dependent plan"
else
    status=$?
fi
[ "$status" = 20 ] || fail "ambiguous model refinements exited $status, want 20"

: >"$issue"
if "$resolver" --harness codex-cli --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then fail "registry-less fixed harness without family must fail"; else status=$?; fi
[ "$status" = 20 ] || fail "registry-less missing family exited $status, want 20"
out="$("$resolver" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$available" --issue-labels "$issue")" || fail "registry-less trusted family failed"
printf '%s\n' "$out" | grep -Fx 'target_label=claim:gpt' >/dev/null || fail "registry-less trusted family selected wrong target"
printf '%s\n' agent:codex >"$issue"
out="$("$resolver" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/legacy-available" --issue-labels "$issue")" || fail "registry-less legacy claim must remain idempotent"
printf '%s\n' "$out" | grep -Fx 'existing_label=agent:codex' >/dev/null || fail "registry-less legacy claim was misclassified"
: >"$issue"
out="$("$resolver" --harness codex-cli --runtime-family gpt --project-management github --available-labels "$tmp/legacy-available" --issue-labels "$issue")" || fail "registry-less legacy fallback failed"
printf '%s\n' "$out" | grep -Fx 'target_label=agent:codex' >/dev/null || fail "registry-less resolver selected the wrong legacy fallback"
for malformed_family in -gpt gpt- gpt--next; do
    if "$resolver" --harness codex-cli --runtime-family "$malformed_family" --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then
        fail "registry-less malformed family '$malformed_family' must fail"
    else
        status=$?
    fi
    [ "$status" = 20 ] || fail "registry-less malformed family '$malformed_family' exited $status, want 20"
done
for malformed_model in -sol sol- sol--next; do
    if "$resolver" --harness codex-cli --runtime-family gpt --claim-model "$malformed_model" --project-management github --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then
        fail "registry-less malformed model '$malformed_model' must fail"
    else
        status=$?
    fi
    [ "$status" = 20 ] || fail "registry-less malformed model '$malformed_model' exited $status, want 20"
done

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

printf '%s\n' claim:gpt:model:extra >"$issue"
if run --harness codex-cli --runtime-family gpt >/dev/null 2>&1; then fail "malformed same-family claim marker must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "malformed same-family claim marker exited $status, want 20"

printf '%s\n' 'agent:foo bar' >"$issue"
if run --harness codex-cli --runtime-family gpt >/dev/null 2>&1; then fail "malformed legacy ownership marker must fail closed"; else status=$?; fi
[ "$status" = 20 ] || fail "malformed legacy marker exited $status, want 20"

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
printf '%s\n' claim:claude >"$issue"
if "$resolver" --registry agent-registry.json --harness codex-cli \
    --runtime-family gpt --project-management none \
    --available-labels "$available" --issue-labels "$issue" >"$tmp/out" 2>&1; then
    fail "label-less takeover should require approval"
else
    status=$?
fi
[ "$status" = 10 ] || fail "label-less takeover exited $status, want 10"
grep -Fx 'target_label=n/a' "$tmp/out" >/dev/null || fail "label-less takeover did not preserve the n/a target"
if "$resolver" --registry agent-registry.json --harness codex-cli \
    --runtime-family gpt --project-management github \
    --available-labels "$available" --issue-labels "$issue" >/dev/null 2>&1; then
    fail "project_management=github without ownership labels must fail closed"
else
    status=$?
fi
[ "$status" = 20 ] || fail "label-less github mode exited $status, want 20"
: >"$issue"
out="$("$resolver" --registry agent-registry.json --harness codex-cli \
    --runtime-family gpt --project-management github --allow-unlabeled-github \
    --available-labels "$available" --issue-labels "$issue")" ||
    fail "approved label-less github fallback failed"
printf '%s\n' "$out" | grep -Fx 'family=gpt' >/dev/null ||
    fail "approved label-less github fallback lost the acting family"
printf '%s\n' "$out" | grep -Fx 'target_label=n/a' >/dev/null ||
    fail "approved label-less github fallback did not select n/a"
printf '%s\n' "$out" | grep -Fx 'existing_label=' >/dev/null ||
    fail "approved label-less github fallback reported an existing marker"
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
grep -F "if ! registry_entry=\"\$(git ls-tree \"\$default\" -- ':(top)agent-registry.json')\"; then" ai/skills/universal/claim/SKILL.md >/dev/null || fail "registry existence probe must be root-relative and fail closed"
grep -F 'if ! git show "$default:agent-registry.json" >"$registry"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "present registry read must fail closed"
grep -F -- '--project-management "$project_management"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must pass the trusted project mode"
grep -F 'unlabeled_github_arg=(--allow-unlabeled-github)' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must expose only the approved label-less GitHub continuation"
grep -F 'user_approved_unlabeled_github_claim=no' ai/skills/universal/claim/SKILL.md >/dev/null || fail "label-less approval must start from an invocation-local denial"
grep -F 'approved_takeover_label=' ai/skills/universal/claim/SKILL.md >/dev/null || fail "takeover approval must start empty in each invocation"
if grep -F '${user_approved_unlabeled_github_claim:-' ai/skills/universal/claim/SKILL.md >/dev/null; then
    fail "label-less approval must never fall back to an inherited environment value"
fi
grep -F 'if [ -z "$approved_takeover_label" ]; then' ai/skills/universal/claim/SKILL.md >/dev/null || fail "single-conflict takeover must stop without explicit approval"
grep -F 'grep -Fqx "conflict_label=$approved_takeover_label"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "takeover approval must name the exact resolver conflict"
grep -F 'target="$(plan_value target_label)"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must extract the selected target"
grep -F 'family_target="$(plan_value family_label)"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must extract the family marker"
grep -F 'model_target="$(plan_value model_label)"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must extract the model marker"
grep -F 'displaced=none' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must initialize displacement to none"
grep -F '[ "$resolver_status" -ne 10 ] || displaced="$approved_takeover_label"' ai/skills/universal/claim/SKILL.md >/dev/null || fail "claim procedure must bind displacement to the approved conflict"
grep -F '[ "$target" = "n/a" ] && family_target=none' ai/skills/universal/claim/SKILL.md >/dev/null || fail "label-less takeover must omit the add-label operation"
if grep -Eq 'claim:(claude|gpt)|agent:(claude-code|codex)' \
    ai/skills/universal/track-work/references/claim-lifecycle.md; then
    fail "canonical claim lifecycle examples must use portable family placeholders"
fi

(
    cd ai/skills
    registry_entry="$(git ls-tree HEAD -- ':(top)agent-registry.json')"
    [ -n "$registry_entry" ] || fail "root registry probe disappeared from a subdirectory"
)

runtime() {
    env -i PATH="$PATH" "$@" "$runtime_resolver"
}

if grep -Eq '\$\{[^}]*,,' "$runtime_resolver"; then
    fail "runtime resolver must remain compatible with macOS Bash 3.2"
fi

[ "$(runtime)" = host ] || fail "an execution host without container signals must resolve to host"
[ "$(runtime REMOTE_CONTAINERS=TRUE)" = devcontainer ] || fail "runtime signal matching must remain case-insensitive"
[ "$(runtime REMOTE_CONTAINERS=true)" = devcontainer ] || fail "the devcontainer signal was not recognized"
[ "$(runtime CODER_AGENT_URL=https://coder.invalid REMOTE_CONTAINERS=true)" = coder ] ||
    fail "Coder must outrank its inherited devcontainer signal"
[ "$(runtime CODESPACES=true REMOTE_CONTAINERS=true)" = codespace ] ||
    fail "Codespaces must outrank its inherited devcontainer signal"
[ "$(runtime GITHUB_ACTIONS=true CODESPACES=true)" = github-actions ] ||
    fail "GitHub Actions must have deterministic precedence"
[ "$(runtime CI=true)" = unknown ] || fail "unclassified automation must use the unknown fallback"
[ "$(runtime REMOTE_CONTAINERS=unexpected)" = unknown ] ||
    fail "a malformed environment signal must use the unknown fallback"
if env -i PATH="$PATH" "$runtime_resolver" extra >/dev/null 2>&1; then
    fail "the runtime resolver must reject caller-supplied identity"
fi
if rg -n 'HOSTNAME|hostname|COMPUTERNAME' "$runtime_resolver" >/dev/null; then
    fail "the portable runtime resolver must not read or publish a machine name"
fi

echo 'PASS: portable claim family and runtime resolution'
