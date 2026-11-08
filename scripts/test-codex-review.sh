#!/usr/bin/env bash
# test-codex-review.sh — offline unit tests for scripts/codex-review.sh's
# target selection and prompt assembly. A stub `codex` on PATH records its
# arguments, so no network, auth, or real review is involved. Guards the
# regression a real adversarial review caught: with no local main/master and
# origin/HEAD pointing at another default branch, the base fallback used to
# strip `origin/` into a nonexistent local ref and silently report nothing
# to review, and the one a real --base run caught: an empty scope reached
# Codex, whose "that diff is empty" reply exited 0 and read as the clean pass
# a capped review loop exits on. Also guards the scope union: a branch holding
# commits AND uncommitted work is the ordinary mid-loop state, and reviewing
# only one half is how a re-run banks a clean pass for a fraction of the
# change. And guards the review guidelines (harmon-init#1530): the table and
# the file are read from the review's BASE revision, never the working tree;
# the unconfigured prompt is held to a golden copy byte for byte; and the
# severity scale's normative statement in docs/review-guidelines.md and the
# prompt's copy are compared, so the two sites can never disagree (#964).
# Run via `task test:codex-review`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# Stub codex: record argv separately from stdout/stderr so filtered banner
# output cannot splice into argument assertions. STUB_BIG_STDERR
# and STUB_EXIT arm the payload-dump reproduction and a failing CLI; both are
# off unless set, so every other test sees the plain stub.
mkdir -p "${test_tmp}/bin"
cat >"${test_tmp}/bin/codex" <<'CODEXSTUB'
#!/usr/bin/env bash
printf 'OpenAI Codex (test)\n--------\n' >&2
[ -z "${STUB_EFFORT-high}" ] || printf 'reasoning effort: %s\n' "${STUB_EFFORT-high}" >&2
printf '%s\n' '--------' user >&2
[ -z "${STUB_AFTER_BANNER:-}" ] || printf '%s\n' "$STUB_AFTER_BANNER" >&2
{
    printf 'STUB-ARGS:'
    printf ' %s' "$@"
    printf '\n'
} >"$STUB_ARGV"
[ -z "${STUB_CWD_FILE:-}" ] || pwd -P >"$STUB_CWD_FILE"
if [ -n "${STUB_BIG_STDERR:-}" ]; then
    # One over-long stderr line (the models-JSON dump), ordinary narration
    # around it, and a long prose line on stdout standing in for a verdict.
    awk -v n="${STUB_BIG_STDERR}" 'BEGIN { l = ""; while (length(l) < n) l = l "PAYLOAD"; printf "ERROR codex_models_manager: simulated payload dump; body: %s\n", l }' >&2
    echo "short stderr narration" >&2
    awk 'BEGIN { p = ""; while (length(p) < 4000) p = p "verdict prose "; printf "P0 finding: %s\n", p }'
fi
last=''
for arg in "$@"; do last=$arg; done
if [ "$last" = "-" ]; then printf "STUB-PROMPT:%s\n" "$(cat)"; fi
exit "${STUB_EXIT:-0}"
CODEXSTUB
chmod +x "${test_tmp}/bin/codex"
PATH="${test_tmp}/bin:${PATH}"
export PATH
stub_argv="${test_tmp}/stub-argv"
export STUB_ARGV="$stub_argv"

git_t() {
    git -c user.email=test@test -c user.name=test "$@"
}

run_tty() {
    # Gate toggles demand a TTY on stdin; allocate a pty so fixtures can get
    # past the interactivity guard and exercise the logic behind it (macOS
    # and util-linux `script` have incompatible CLIs).
    if [ "$(uname)" = "Darwin" ]; then
        script -q /dev/null "$@" </dev/null
    else
        # printf %q keeps argv intact through script -c's shell reparse
        # (paths with spaces/metacharacters would split under a bare $*).
        script -qec "$(printf '%q ' "$@")" /dev/null </dev/null
    fi
}

# Fixture: an upstream whose default branch is `develop` (not main/master),
# and a clone with only origin/develop plus a feature branch.
git init -q -b develop "${test_tmp}/upstream"
(
    cd "${test_tmp}/upstream"
    mkdir -p scripts/lib
    cp "${repo}/scripts/codex-review.sh" scripts/
    # The mode and severity prose are shared assets the script reads at render
    # time (scripts/lib/review-instructions/); a fake repo without them is not
    # a runnable copy of the script.
    mkdir -p scripts/lib
    cp -R "${repo}/scripts/lib/review-instructions" scripts/lib/
    cp "${repo}/scripts/lib/review-scope.sh" scripts/lib/
    git add -A
    git_t commit -q -m base
)
git clone -q "${test_tmp}/upstream" "${test_tmp}/clone"
cd "${test_tmp}/clone"
git checkout -q -b feature
echo change >feature.txt
git add feature.txt
git_t commit -q -m work
git branch -q -D develop

invoke_review() {
    : >"$stub_argv"
    ./scripts/codex-review.sh "$@"
}

run() {
    invoke_review "$@" 2>&1
}

. "${repo}/ai/skills/repo/standardize-repo/assets/test-render-bundle.sh" --fixture-functions

echo "==> standardize excludes only pristine frozen-render paths and keeps protected or customized files"
std_repo="${test_tmp}/standardize-repo"
std_bundle="${test_tmp}/standardize-bundle"
mkdir -p "$std_repo/scripts/lib" "$std_repo/.claude/skills/standardize-repo/assets" \
    "$std_repo/src" "$std_bundle/previous/src" "$std_bundle/current/src"
cp "${repo}/scripts/codex-review.sh" "$std_repo/scripts/"
cp "${repo}/scripts/lib/review-scope.sh" "$std_repo/scripts/lib/"
cp -R "${repo}/scripts/lib/review-instructions" "$std_repo/scripts/lib/"
cp "${repo}/ai/skills/repo/standardize-repo/assets/"{diff-template,render-bundle}.sh \
    "$std_repo/.claude/skills/standardize-repo/assets/"
git init -q -b main "$std_repo"
git -C "$std_repo" config user.email test@test
git -C "$std_repo" config user.name test
printf 'template old\n' >"$std_repo/src/generated.txt"
printf 'repository customization old\n' >"$std_repo/src/customized.txt"
printf '_commit: v1.0.0\n' >"$std_repo/.copier-answers.yml"
printf 'conflict old\n' >"$std_repo/src/conflict-resolution.txt"
printf 'owned old\n' >"$std_repo/src/repo-owned.txt"
printf 'mode\n' >"$std_repo/src/mode-change.sh"
chmod 644 "$std_repo/src/mode-change.sh"
git -C "$std_repo" add -A
git -C "$std_repo" commit -qm 'test: standardize base'
std_base="$(git -C "$std_repo" rev-parse HEAD)"
git -C "$std_repo" checkout -qb update
printf 'template new\n' >"$std_repo/src/generated.txt"
printf 'repository customization new\n' >"$std_repo/src/customized.txt"
printf '_commit: v2.0.0\n' >"$std_repo/.copier-answers.yml"
printf 'conflict new\n' >"$std_repo/src/conflict-resolution.txt"
printf 'owned new\n' >"$std_repo/src/repo-owned.txt"
chmod +x "$std_repo/src/mode-change.sh"
git -C "$std_repo" add -A
git -C "$std_repo" commit -qm 'test: standardize update'
std_head="$(git -C "$std_repo" rev-parse HEAD)"
printf 'template old\n' >"$std_bundle/previous/src/generated.txt"
printf 'template new\n' >"$std_bundle/current/src/generated.txt"
printf 'template old\n' >"$std_bundle/previous/src/customized.txt"
printf 'template new\n' >"$std_bundle/current/src/customized.txt"
printf '_commit: v1.0.0\n' >"$std_bundle/previous/.copier-answers.yml"
printf '_commit: v2.0.0\n' >"$std_bundle/current/.copier-answers.yml"
printf 'conflict old\n' >"$std_bundle/previous/src/conflict-resolution.txt"
printf 'conflict new\n' >"$std_bundle/current/src/conflict-resolution.txt"
printf 'owned old\n' >"$std_bundle/previous/src/repo-owned.txt"
printf 'owned new\n' >"$std_bundle/current/src/repo-owned.txt"
printf 'mode\n' >"$std_bundle/previous/src/mode-change.sh"
printf 'mode\n' >"$std_bundle/current/src/mode-change.sh"
chmod 644 "$std_bundle/previous/src/mode-change.sh" "$std_bundle/current/src/mode-change.sh"
printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.0.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
    "$std_base" "$std_head" >"$std_bundle/metadata"
printf 'src/conflict-resolution.txt\0' >"$std_bundle/conflict-resolutions.nul"
printf 'src/repo-owned.txt\0' >"$std_bundle/repo-owned.nul"
render_bundle_fixture "$std_bundle" "$std_repo" "$std_base" "$std_head" v2.0.0
printf 'src/generated.txt\0' >"${test_tmp}/standardize-expected.nul"
bash "$std_repo/.claude/skills/standardize-repo/assets/diff-template.sh" \
    --review-exclusions --release v2.0.0 --frozen-render "$std_bundle" \
    --base "$std_base" --head "$std_head" "$std_repo" \
    >"${test_tmp}/standardize-actual.nul" || fail "frozen-render exclusion computation failed"
cmp -s "${test_tmp}/standardize-expected.nul" "${test_tmp}/standardize-actual.nul" ||
    fail "the exclusion list must contain only the pristine rendered file"
: >"$stub_argv"
out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
    --release v2.0.0 --frozen-render "$std_bundle" --base "$std_base" 2>&1)" ||
    fail "standardize Codex review failed: $out"
! grep -Fq 'src/generated.txt' <<<"$out" || fail "pristine template path remained in the review manifest: $out"
for kept_path in src/customized.txt .copier-answers.yml src/conflict-resolution.txt \
    src/repo-owned.txt src/mode-change.sh; do
    grep -Fq "$kept_path" <<<"$out" || fail "standardize review omitted protected/customized path $kept_path: $out"
done
filtered_diff="$(cd "$std_repo" && bash -c '
    . ./scripts/lib/review-scope.sh
    resolve_review_scope --profile standardize --release "$1" --frozen-render "$2" --base "$3"
    review_scope_apply_profile
    collect_review_diff
' _ v2.0.0 "$std_bundle" "$std_base")" || fail "standardize diff collection failed"
! grep -Fq 'src/generated.txt' <<<"$filtered_diff" ||
    fail "the review diff included a pristine template-only file: $filtered_diff"
grep -Fq 'src/customized.txt' <<<"$filtered_diff" ||
    fail "the review diff omitted the customized file: $filtered_diff"
grep -Fq 'filed upstream' <<<"$out" || fail "standardize profile did not render the upstream filing default"
grep -Fq 'A confirmed P0 or P1' <<<"$out" || fail "standardize profile did not preserve severity gating"
if out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
    --frozen-render "$std_bundle" --base "$std_base" 2>&1)"; then
    fail "standardize profile accepted a missing --release"
fi
grep -Fq -- '--profile standardize requires --release' <<<"$out" ||
    fail "missing release refusal did not name the required input: $out"
if out="$(cd "$std_repo" && bash .claude/skills/standardize-repo/assets/diff-template.sh \
    --review-exclusions --release v9.9.9 --frozen-render "$std_bundle" \
    --base "$std_base" --head "$std_head" "$std_repo" 2>&1)"; then
    fail "frozen-render helper accepted a bundle bound to another release"
fi
grep -Fq 'bundle release does not match --release' <<<"$out" ||
    fail "release mismatch refusal did not identify the binding error: $out"

echo "==> standardize refuses a filtered scope over 200 entries before invoking codex"
git -C "$std_repo" checkout -qb too-many-standardize "$std_base"
i=1
while [ "$i" -le 201 ]; do
    printf 'customized %s\n' "$i" >"$std_repo/src/custom-${i}.txt"
    i=$((i + 1))
done
git -C "$std_repo" add -A
git -C "$std_repo" commit -qm 'test: add more than 200 customized paths'
large_head="$(git -C "$std_repo" rev-parse HEAD)"
large_bundle="${test_tmp}/large-standardize-bundle"
mkdir -p "$large_bundle/previous" "$large_bundle/current"
printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.0.1\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
    "$std_base" "$large_head" >"$large_bundle/metadata"
: >"$large_bundle/conflict-resolutions.nul"
: >"$large_bundle/repo-owned.nul"
render_bundle_fixture "$large_bundle" "$std_repo" "$std_base" "$large_head" v2.0.1
: >"$stub_argv"
if out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
    --release v2.0.1 --frozen-render "$large_bundle" --base "$std_base" 2>&1)"; then
    fail "standardize accepted a filtered scope over 200 entries: $out"
fi
grep -Fq 'standardize profile refuses review scopes over 200 entries' <<<"$out" ||
    fail "oversized standardize refusal did not explain the limit: $out"
[ ! -s "$stub_argv" ] || fail "codex was invoked for an oversized standardize scope: $(cat "$stub_argv")"
git -C "$std_repo" checkout -q update

echo "==> a head edit to the consumer-layout helper cannot change standardize exclusions"
cat >"$std_repo/.claude/skills/standardize-repo/assets/diff-template.sh" <<'HEADHELPER'
#!/usr/bin/env bash
if [ "${1:-}" = --review-exclusions ]; then
    printf 'src/customized.txt\0'
    exit 0
fi
exit 2
HEADHELPER
chmod +x "$std_repo/.claude/skills/standardize-repo/assets/diff-template.sh"
git -C "$std_repo" add .claude/skills/standardize-repo/assets/diff-template.sh
git -C "$std_repo" commit -qm 'test: head helper tries to exclude a customization'
std_head_tampered="$(git -C "$std_repo" rev-parse HEAD)"
export HARMON_INIT="${std_bundle}-template"
rm -rf "$std_bundle"
bash "${repo}/ai/skills/repo/standardize-repo/assets/render-bundle.sh" \
    --previous-release v1.0.0 --release v2.0.0 --base "$std_base" \
    --head "$std_head_tampered" --output "$std_bundle" "$std_repo"
printf 'src/conflict-resolution.txt\0' >"$std_bundle/conflict-resolutions.nul"
out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
    --release v2.0.0 --frozen-render "$std_bundle" --base "$std_base" 2>&1)" ||
    fail "standardize review with a head-edited helper failed: $out"
grep -Fq 'src/generated.txt' <<<"$out" &&
    fail "the base helper's pristine generated path was not excluded: $out"
grep -Fq 'src/customized.txt' <<<"$out" ||
    fail "the head helper changed the base helper's exclusions: $out"

echo "==> a merge-base helper without --review-exclusions is refused"
unsupported_repo="${test_tmp}/standardize-unsupported-helper-repo"
mkdir -p "$unsupported_repo/scripts/lib" \
    "$unsupported_repo/.claude/skills/standardize-repo/assets" "$unsupported_repo/src"
cp "${repo}/scripts/codex-review.sh" "$unsupported_repo/scripts/"
cp "${repo}/scripts/lib/review-scope.sh" "$unsupported_repo/scripts/lib/"
cp -R "${repo}/scripts/lib/review-instructions" "$unsupported_repo/scripts/lib/"
cat >"$unsupported_repo/.claude/skills/standardize-repo/assets/diff-template.sh" <<'LEGACYHELPER'
#!/usr/bin/env bash
echo "FAIL: unknown argument '$1'" >&2
exit 2
LEGACYHELPER
chmod +x "$unsupported_repo/.claude/skills/standardize-repo/assets/diff-template.sh"
git init -q -b main "$unsupported_repo"
git -C "$unsupported_repo" config user.email test@test
git -C "$unsupported_repo" config user.name test
printf 'old\n' >"$unsupported_repo/src/app.txt"
git -C "$unsupported_repo" add -A
git_t -C "$unsupported_repo" commit -qm 'test: legacy helper base'
unsupported_base="$(git -C "$unsupported_repo" rev-parse HEAD)"
git -C "$unsupported_repo" checkout -qb update
cp "${repo}/ai/skills/repo/standardize-repo/assets/diff-template.sh" \
    "$unsupported_repo/.claude/skills/standardize-repo/assets/diff-template.sh"
printf 'new\n' >"$unsupported_repo/src/app.txt"
git -C "$unsupported_repo" add -A
git_t -C "$unsupported_repo" commit -qm 'test: update helper only at head'
if out="$(cd "$unsupported_repo" && ./scripts/codex-review.sh review --profile standardize \
    --release v2.0.0 --frozen-render "${test_tmp}/unused-bundle" \
    --base "$unsupported_base" 2>&1)"; then
    fail "standardize profile accepted a merge-base helper without --review-exclusions"
fi
grep -Fq "standardize profile unavailable at merge base $unsupported_base" <<<"$out" ||
    fail "unsupported-helper refusal did not name the merge base: $out"
grep -Fq 'the helper does not support --review-exclusions' <<<"$out" ||
    fail "unsupported-helper refusal did not explain the missing capability: $out"

echo "==> a standardize filter that would empty the diff falls back to the full diff"
git -C "$std_repo" checkout -qb all-pristine "$std_base"
printf 'template all-pristine update\n' >"$std_repo/src/generated.txt"
git -C "$std_repo" add src/generated.txt
git -C "$std_repo" commit -qm 'test: only pristine template update'
fallback_head="$(git -C "$std_repo" rev-parse HEAD)"
fallback_bundle="${test_tmp}/fallback-bundle"
mkdir -p "$fallback_bundle/previous/src" "$fallback_bundle/current/src"
git -C "$std_repo" show "$std_base:src/generated.txt" >"$fallback_bundle/previous/src/generated.txt"
git -C "$std_repo" show "$fallback_head:src/generated.txt" >"$fallback_bundle/current/src/generated.txt"
printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.1.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
    "$std_base" "$fallback_head" >"$fallback_bundle/metadata"
: >"$fallback_bundle/conflict-resolutions.nul"
: >"$fallback_bundle/repo-owned.nul"
render_bundle_fixture "$fallback_bundle" "$std_repo" "$std_base" "$fallback_head" v2.1.0
out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
    --release v2.1.0 --frozen-render "$fallback_bundle" --base "$std_base" 2>&1)" ||
    fail "all-pristine standardize review failed: $out"
grep -Fq 'full diff is retained under the standardize profile' <<<"$out" ||
    fail "empty-scope fallback was not disclosed: $out"
grep -Fq 'src/generated.txt' <<<"$out" ||
    fail "empty-scope fallback did not restore the full manifest: $out"

echo "==> an oversized all-pristine scope runs on the restored full diff"
oversized_fallback_bundle="${test_tmp}/oversized-fallback-bundle"
git -C "$std_repo" checkout -qb oversized-pristine-base "$std_base"
mkdir -p "$oversized_fallback_bundle/previous/src" "$oversized_fallback_bundle/current/src"
i=1
while [ "$i" -le 201 ]; do
    printf 'template old %s\n' "$i" >"$std_repo/src/pristine-${i}.txt"
    i=$((i + 1))
done
git -C "$std_repo" add -A
git -C "$std_repo" commit -qm 'test: add pristine template paths to base'
oversized_fallback_base="$(git -C "$std_repo" rev-parse HEAD)"
git -C "$std_repo" checkout -qb oversized-all-pristine "$oversized_fallback_base"
i=1
while [ "$i" -le 201 ]; do
    printf 'template new %s\n' "$i" >"$std_repo/src/pristine-${i}.txt"
    printf 'template old %s\n' "$i" >"$oversized_fallback_bundle/previous/src/pristine-${i}.txt"
    printf 'template new %s\n' "$i" >"$oversized_fallback_bundle/current/src/pristine-${i}.txt"
    i=$((i + 1))
done
git -C "$std_repo" add -A
git -C "$std_repo" commit -qm 'test: update more than 200 pristine template paths'
oversized_fallback_head="$(git -C "$std_repo" rev-parse HEAD)"
printf 'format=harmon-devkit-review-frozen-render-v1\nrelease=v2.2.0\nprevious-release=v1.0.0\nbase=%s\nhead=%s\n' \
    "$oversized_fallback_base" "$oversized_fallback_head" >"$oversized_fallback_bundle/metadata"
: >"$oversized_fallback_bundle/conflict-resolutions.nul"
: >"$oversized_fallback_bundle/repo-owned.nul"
render_bundle_fixture "$oversized_fallback_bundle" "$std_repo" "$oversized_fallback_base" "$oversized_fallback_head" v2.2.0
: >"$stub_argv"
out="$(cd "$std_repo" && ./scripts/codex-review.sh review --profile standardize \
    --release v2.2.0 --frozen-render "$oversized_fallback_bundle" \
    --base "$oversized_fallback_base" 2>&1)" ||
    fail "oversized all-pristine standardize review was refused: $out"
grep -Fq 'full diff is retained under the standardize profile' <<<"$out" ||
    fail "oversized all-pristine review did not disclose its full-diff fallback: $out"
grep -Fq 'manifest truncated at 200 entries; re-enumerate with git for the full set' <<<"$out" ||
    fail "oversized full-diff fallback omitted the ordinary re-enumeration marker: $out"
[ -s "$stub_argv" ] || fail "codex was not invoked for the oversized full-diff fallback"
oversized_fallback_paths="$(git -C "$std_repo" diff --name-only \
    "$oversized_fallback_base...$oversized_fallback_head" | wc -l | tr -d '[:space:]')"
[ "$oversized_fallback_paths" = 201 ] ||
    fail "oversized full-diff fixture contains $oversized_fallback_paths paths, expected 201"

echo "==> clean tree, no local main/master: falls back to origin/HEAD's branch"
out="$(run challenge)" || fail "challenge exited non-zero: $out"
grep -q "STUB-ARGS: exec review" "$stub_argv" || fail "codex exec review not invoked: $out"
grep -q -- "--model gpt-6.1-sol" "$stub_argv" || fail "review model is not pinned to gpt-6.1-sol: $out"
grep -q -- "--config model_reasoning_effort=high" "$stub_argv" || fail "review reasoning is not pinned high: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "remote-qualified fallback base missing: $out"
grep -q "ADVERSARIAL" <<<"$out" || fail "challenge mode instructions missing: $out"
grep -q "feature.txt" <<<"$out" || fail "changed-file manifest missing from branch-scope prompt: $out"
# A clean tree has no second half, so the split manifest must not appear —
# otherwise the union headers would be noise the reviewer has to interpret.
grep -q "Uncommitted changes (git status" <<<"$out" && fail "clean tree emitted an uncommitted manifest section: $out"
# The gate is only meaningful if the scale it gates on is defined in the
# prompt — Codex's own priority labels are an undocumented convention.
grep -q "Only P0 and P1 decide" <<<"$out" || fail "challenge prompt missing the P0/P1 gating rule: $out"
grep -q "Still report P2s" <<<"$out" || fail "challenge prompt missing the report-P2s instruction: $out"
# An unreported P2 never reaches the PR body, so the handoff clause is what
# makes "reported but non-gating" different from "ignored".
grep -q "carried into the pull request description" <<<"$out" || fail "challenge prompt missing the P2 handoff clause: $out"
# P3 is cosmetic and the cloud reviewer emits badges this prompt never sent,
# so both the fourth level and the off-scale floor have to survive edits.
# The prompt assertions below read the RENDERED instructions, so they cannot
# see a stale claim in the script's own header comment — which is exactly how
# one survived the P3 rewording (harmon-init#923 shepherd r3). Assert against
# the SOURCE too, so a summary that contradicts the prompt fails here rather
# than in review.
if grep -q "never deferred" "${repo}/scripts/codex-review.sh"; then
    fail "codex-review.sh's header still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge"
fi

grep -q "P3 — cosmetic" <<<"$out" || fail "challenge prompt missing the P3 level: $out"
grep -q "adjudicated as at least a P2" <<<"$out" || fail "challenge prompt missing the off-scale badge floor: $out"
grep -q "hypothesis the" <<<"$out" ||
    fail "challenge prompt missing the label-is-a-hypothesis rule — an under-labelled P3 could be dropped without adjudication (harmon-init#923 shepherd r2): $out"
! grep -q "not carried into the pull request description" <<<"$out" ||
    fail "challenge prompt still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge: $out"

echo "==> explicit model and reasoning selection preserves target and focus parsing"
out="$(run challenge --model gpt-5.6-terra --reasoning medium --base origin/develop inspect dispatch)" ||
    fail "explicit model/reasoning run exited non-zero: $out"
grep -q -- "--model gpt-5.6-terra" "$stub_argv" || fail "explicit review model did not reach Codex: $out"
grep -q -- "--config model_reasoning_effort=medium" "$stub_argv" || fail "explicit review reasoning did not reach Codex: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "explicit model/reasoning consumed the target: $out"
grep -q "inspect dispatch" <<<"$out" || fail "explicit model/reasoning consumed the focus text: $out"

echo "==> effort: match is recorded without a warning, including strict mode"
out="$(STUB_EFFORT=high run review --reasoning high --require-effort)" || fail "matching effort refused: $out"
grep -q 'requested=high effective=high source=banner matched=true' <<<"$out" || fail "missing match record"
! grep -q 'WARNING: Codex reasoning effort' <<<"$out" || fail "matching effort warned"

echo "==> effort: managed override warns by default and fails only under strict mode"
out="$(STUB_EFFORT=medium run challenge --reasoning high)" || fail "default mismatch changed exit status: $out"
grep -q 'WARNING: Codex reasoning effort mismatch: requested=high effective=medium' <<<"$out" || fail "missing mismatch warning"
grep -q 'source=banner matched=false' <<<"$out" || fail "missing mismatch record"
rc=0
out="$(STUB_EFFORT=medium run review --reasoning high --require-effort)" || rc=$?
[ "$rc" -eq 1 ] || fail "strict mismatch exited $rc"
grep -q 'requested=high effective=medium' <<<"$out" || fail "strict error does not name efforts"
grep -q -- '--require-effort refuses' <<<"$out" || fail "missing strict refusal"

echo "==> effort: absent or conflicting readouts stay unknown; strict refuses them"
for banner in '' $'high\nreasoning effort: medium'; do
    out="$(STUB_EFFORT="$banner" run review)" || fail "unknown changed default exit status"
    grep -q 'effective=unknown source=unknown matched=false' <<<"$out" || fail "unknown effort was assumed: $out"
    rc=0
    out="$(STUB_EFFORT="$banner" run review --require-effort)" || rc=$?
    [ "$rc" -eq 1 ] || fail "strict unknown exited $rc"
done

echo "==> effort: later reviewer prose cannot impersonate a startup readout"
out="$(STUB_EFFORT=medium STUB_AFTER_BANNER=$'user\nreasoning effort: high' run review)" || fail "later readout failed"
grep -q 'effective=medium source=banner matched=false' <<<"$out" || fail "later prose altered readout"

echo "==> effort: parsing precedes line truncation and CLI failures retain their status"
out="$(STUB_EFFORT=high CODEX_REVIEW_MAX_STDERR_BYTES=1 run review --require-effort)" || fail "truncated banner lost effort"
grep -q 'effective=high source=banner matched=true' <<<"$out" || fail "truncation changed effort"
for strict in '' --require-effort; do
    rc=0
    # An empty unquoted expansion supplies no flag; this is intentional.
    out="$(STUB_EFFORT=medium STUB_EXIT=7 run review $strict)" || rc=$?
    [ "$rc" -eq 7 ] || fail "effort check replaced CLI exit 7 with $rc"
done

echo "==> invalid explicit model and reasoning arguments fail before Codex"
if out="$(run review --model 2>&1)"; then
    fail "--model without a value was accepted: $out"
fi
grep -q -- "--model requires a value" <<<"$out" || fail "missing-value model error absent: $out"
grep -q "STUB-ARGS" "$stub_argv" && fail "Codex invoked despite missing model value: $out"
if out="$(run review --reasoning extreme 2>&1)"; then
    fail "unsupported reasoning level was accepted: $out"
fi
grep -q "unsupported reasoning level" <<<"$out" || fail "unsupported-reasoning error absent: $out"
grep -q "STUB-ARGS" "$stub_argv" && fail "Codex invoked despite unsupported reasoning: $out"

echo "==> an external trusted runner reviews the target root without executing target runner bytes"
external_target="${test_tmp}/external-target"
git clone -q "${test_tmp}/upstream" "$external_target"
git -C "$external_target" checkout -qb candidate
target_runner_marker="${test_tmp}/target-runner-executed"
target_library_marker="${test_tmp}/target-library-executed"
cat >"$external_target/scripts/codex-review.sh" <<'TARGETRUNNER'
#!/usr/bin/env bash
: >"$TARGET_RUNNER_MARKER"
exit 91
TARGETRUNNER
cat >"$external_target/scripts/lib/review-scope.sh" <<'TARGETLIBRARY'
: >"$TARGET_LIBRARY_MARKER"
exit 92
TARGETLIBRARY
printf 'candidate-only instructions\n' >"$external_target/scripts/lib/review-instructions/standardize.txt"
printf 'candidate change\n' >"$external_target/candidate.txt"
git -C "$external_target" add -A
git_t -C "$external_target" commit -qm 'test: change candidate finder bytes'
external_target="$(cd "$external_target" && pwd -P)"
stub_cwd="${test_tmp}/external-codex-cwd"
out="$(TARGET_RUNNER_MARKER="$target_runner_marker" TARGET_LIBRARY_MARKER="$target_library_marker" \
    STUB_CWD_FILE="$stub_cwd" "${repo}/scripts/codex-review.sh" challenge \
    --repo-root "$external_target" --base origin/develop 2>&1)" ||
    fail "trusted external runner failed: $out"
[ "$(cat "$stub_cwd")" = "$external_target" ] ||
    fail "codex ran outside the target root: $(cat "$stub_cwd")"
[ ! -e "$target_runner_marker" ] || fail "the target's codex-review.sh executed"
[ ! -e "$target_library_marker" ] || fail "the target's review-scope.sh executed"
grep -Fq 'candidate.txt' <<<"$out" || fail "trusted runner did not scope the target diff: $out"
grep -Fq 'scripts/codex-review.sh' <<<"$out" || fail "target runner change missing from the review manifest: $out"
grep -Fq 'scripts/lib/review-scope.sh' <<<"$out" || fail "target library change missing from the review manifest: $out"

echo "==> an external trusted runner accepts an empty forwarded-argument list under nounset"
out="$(TARGET_RUNNER_MARKER="$target_runner_marker" TARGET_LIBRARY_MARKER="$target_library_marker" \
    STUB_CWD_FILE="$stub_cwd" "${repo}/scripts/codex-review.sh" challenge \
    --repo-root "$external_target" 2>&1)" ||
    fail "trusted external runner failed with only --repo-root: $out"
grep -Fq 'candidate.txt' <<<"$out" || fail "empty forwarded arguments did not reach default scope resolution: $out"
grep -Fq 'if [ "${#review_args[@]}" -eq 0 ]; then' "${repo}/scripts/codex-review.sh" ||
    fail "runner lost the explicit Bash 3.2/4.3 empty-array guard"

echo "==> --repo-root refuses a target subdirectory"
if out="$("${repo}/scripts/codex-review.sh" review --repo-root "$external_target/scripts" \
    --base origin/develop 2>&1)"; then
    fail "--repo-root accepted a target subdirectory: $out"
fi
grep -Fq -- '--repo-root must name the Git worktree root' <<<"$out" ||
    fail "target-subdirectory refusal did not name the root requirement: $out"

echo "==> an external trusted runner preserves the finder exit status"
status=0
STUB_EXIT=7 "${repo}/scripts/codex-review.sh" review --repo-root "$external_target" \
    --base origin/develop >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "external runner lost the finder exit status (got ${status}, want 7)"

echo "==> origin/HEAD outranks a stray local main"
git branch -q main "$(git rev-list --max-parents=0 HEAD)"
out="$(run challenge)" || fail "challenge with stray local main exited non-zero: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "stray local main hijacked base detection: $out"
git branch -q -D main

echo "==> --base with no merge base fails fast"
unrelated="$(git_t commit-tree "$(git mktree </dev/null)" -m orphan)"
if out="$(run review --base "$unrelated" 2>&1)"; then
    fail "--base with unrelated history accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite no merge base: $out"
grep -q "no merge base" <<<"$out" || fail "missing no-merge-base message: $out"

echo "==> explicit --base and focus text reach the prompt"
out="$(run review --base origin/develop watch the hooks)" || fail "review --base exited non-zero: $out"
grep -q "base branch 'origin/develop'" <<<"$out" || fail "--base not honored: $out"
grep -q "VERIFICATION-CHECKPOINT" <<<"$out" || fail "review mode instructions missing: $out"
grep -q "watch the hooks" <<<"$out" || fail "focus text missing from prompt: $out"
grep -q "Only P0 and P1 decide" <<<"$out" || fail "review prompt missing the P0/P1 gating rule: $out"
grep -q "carried into the pull request description" <<<"$out" || fail "review prompt missing the P2 handoff clause: $out"
grep -q "P3 — cosmetic" <<<"$out" || fail "review prompt missing the P3 level: $out"
grep -q "adjudicated as at least a P2" <<<"$out" || fail "review prompt missing the off-scale badge floor: $out"
grep -q "hypothesis the" <<<"$out" ||
    fail "review prompt missing the label-is-a-hypothesis rule — an under-labelled P3 could be dropped without adjudication (harmon-init#923 shepherd r2): $out"
! grep -q "not carried into the pull request description" <<<"$out" ||
    fail "review prompt still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge: $out"

# ── Review guidelines (harmon-init#1530) ─────────────────────────────────────
# Everything after STUB-PROMPT: (up to the runner's own effort record) is the
# prompt codex received, byte for byte.
prompt_of() {
    # The runner prints its effort record on stderr after the stub's stdout;
    # it is not part of the prompt.
    sed -n '/^STUB-PROMPT:/,$p' <<<"$1" | sed '1s/^STUB-PROMPT://' | sed '/^Codex reasoning effort: /,$d'
}
# A fresh repository carrying the runner, on main. Callers add the files each
# case needs and commit; the runner's own bytes are the ones under test.
guidelines_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/scripts/lib" "$fixture/docs"
    cp "${repo}/scripts/codex-review.sh" "$fixture/scripts/"
    cp "${repo}/scripts/lib/review-scope.sh" "$fixture/scripts/lib/"
    cp -R "${repo}/scripts/lib/review-instructions" "$fixture/scripts/lib/"
    git init -q -b main "$fixture"
}
# A stand-in policy reader at a fixture's base revision: prints the JSON its
# body carries, after proving it was handed the BASE copy of .devflow.toml (a
# branch copy carries a different marker). Deterministic whatever reader the
# repository running this test vendors, so every projection path is covered
# without depending on the pin.
stub_reader() {
    local fixture="$1" json="$2"
    mkdir -p "$fixture/scripts/lib"
    printf 'export const stub = true\n' >"$fixture/scripts/lib/toml-lite.mjs"
    cat >"$fixture/scripts/devflow-policy.mjs" <<STUBREADER
import { readFileSync } from 'node:fs'
import './lib/toml-lite.mjs'
const args = process.argv.slice(2)
if (args[0] !== 'resolve' || !args.includes('--json')) { console.error('stub reader: unexpected arguments', args); process.exit(2) }
const policy = readFileSync(args[args.indexOf('--policy') + 1], 'utf8')
if (!policy.includes('BASE-POLICY-MARKER')) { console.error('stub reader: not the base revision policy'); process.exit(1) }
console.log(JSON.stringify(${json}))
STUBREADER
}

echo "==> unconfigured: the prompt is the built-in text, byte for byte (golden)"
# The clone fixture has no docs/review-guidelines.md and no .devflow.toml at
# its base, so this is the prompt the runner sent before guidelines existed.
# A change to this text is a change to every review; it is made here on
# purpose, never by accident.
golden_file="${test_tmp}/golden-review-prompt"
cat >"$golden_file" <<'GOLDEN'
Review the changes on the current branch relative to base branch 'origin/develop' (the merge-base diff origin/develop...HEAD).

Run a VERIFICATION-CHECKPOINT review of this change: double-check that the
implementation actually does what it claims, is internally consistent and
consistent with this repository's existing conventions and docs, handles
errors and edge cases, and has adequate test coverage (including regression
tests for anything it fixes). Flag docs the change should have updated.
Report only material, defensible findings tied to concrete files and lines —
no style nits. If the change holds up, say so directly.

Label EVERY finding with a priority, as the first token of the finding:

  P0 — a defect that breaks correctness, security, or data integrity in
       ordinary use, or that breaks an existing contract. Merge-blocking.
  P1 — a real defect or materially wrong design decision with a plausible
       trigger. Merge-blocking unless argued down with evidence.
  P2 — worth knowing, but not merge-blocking: hardening, edge cases behind
       unlikely preconditions, maintainability, non-critical test gaps.
  P3 — cosmetic or purely informational: a naming or wording choice that
       will mislead a reader, an observation with no defect behind it.
       Never gating. The no-style-nits rule above still binds — P3 is the
       floor for findings worth stating, not a licence to report nits.

Only P0 and P1 decide whether this review passes. Still report P2s in full —
they are triaged later, once the pull request is open — but do not let them
hold the stage open. Do not inflate a P2 to P1 to make it heard, and do not
withhold or soften a P2 because it is non-gating: a P2 reported here is
carried into the pull request description, so an unreported one is lost
outright. The same holds one level down: report a P3 as a P3 rather than
inflating it to P2 or dropping it for being small. Use these four labels and
no others — a finding that arrives off this scale, or with no label at all,
is adjudicated as at least a P2. Every label you apply is a hypothesis the
reader adjudicates on evidence, P3 included; none of them decides its own
disposition. If there are no P0 or P1 findings, say so
explicitly and in those terms.

Authoritative changed-file manifest from git for this scope (status + path;
cover EVERY entry, including untracked files, collecting the diffs yourself
with git):

GOLDEN
printf 'A\tfeature.txt' >>"$golden_file"
golden="$(cat "$golden_file")"
out="$(run review --base origin/develop)" || fail "unconfigured review exited non-zero: $out"
grep -Fq 'Review guidelines: none at' <<<"$out" || fail "unconfigured run did not say no guidelines govern: $out"
if [ "$(prompt_of "$out")" != "$golden" ]; then
    diff <(printf '%s\n' "$golden") <(prompt_of "$out") >&2 || true
    fail "the unconfigured prompt drifted from its golden copy (above); change both deliberately or neither"
fi

echo "==> the severity scale in docs/review-guidelines.md and in the prompt are the same lines"
# The file holds the scale's single normative statement (#964); the prompt
# carries a copy because it is what the reviewer actually reads. Two copies
# are one too many unless a gate holds them together — this is that gate.
scale_prompt="$(sed -n '/^  P0 — /,/^$/p' <<<"$golden" | sed '$d')"
[ "$(wc -l <<<"$scale_prompt")" -eq 10 ] || fail "could not extract the prompt's scale block: $scale_prompt"
if [ -f "${repo}/docs/review-guidelines.md" ]; then
    scale_doc="$(awk '/^## Severity scale$/ { s = 1 } s && /^```text$/ { f = 1; next } f && /^```$/ { exit } f' "${repo}/docs/review-guidelines.md")"
    [ -n "$scale_doc" ] || fail "docs/review-guidelines.md has no fenced text block under '## Severity scale'"
    if [ "$scale_doc" != "$scale_prompt" ]; then
        diff <(printf '%s\n' "$scale_doc") <(printf '%s\n' "$scale_prompt") >&2 || true
        fail "docs/review-guidelines.md's severity scale differs from the prompt's (above): edit both in the same commit"
    fi
else
    echo "    (docs/review-guidelines.md is absent here; nothing to compare the prompt's scale against)"
fi

echo "==> guidelines come from the base revision: worktree and branch edits do not reach a --base review"
conv="${test_tmp}/guidelines-conventional"
guidelines_fixture "$conv"
printf 'BASE-GUIDELINES-MARKER\n' >"$conv/docs/review-guidelines.md"
printf 'old\n' >"$conv/src.txt"
git -C "$conv" add -A
git_t -C "$conv" commit -qm 'test: base with guidelines'
conv_base="$(git -C "$conv" rev-parse HEAD)"
git -C "$conv" checkout -qb feature
printf 'HEAD-GUIDELINES-MARKER\n' >"$conv/docs/review-guidelines.md"
printf 'new\n' >"$conv/src.txt"
git -C "$conv" add -A
git_t -C "$conv" commit -qm 'test: branch rewrites the guidelines'
conv_head="$(git -C "$conv" rev-parse HEAD)"
printf 'WORKTREE-GUIDELINES-MARKER\n' >"$conv/docs/review-guidelines.md"
out="$(cd "$conv" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "--base review with guidelines failed: $out"
grep -Fq "Review guidelines: docs/review-guidelines.md at $(git -C "$conv" rev-parse --short main)" <<<"$out" ||
    fail "the run did not name the base revision's guidelines: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'BASE-GUIDELINES-MARKER' <<<"$prompt" || fail "base-revision guidelines missing from the --base prompt: $prompt"
! grep -Fq 'HEAD-GUIDELINES-MARKER' <<<"$prompt" || fail "the branch's rewritten guidelines reached the --base prompt: $prompt"
! grep -Fq 'WORKTREE-GUIDELINES-MARKER' <<<"$prompt" || fail "a working-tree edit to the guidelines reached the --base prompt: $prompt"
grep -Fq "Repository review guidelines (docs/review-guidelines.md, read at $(git -C "$conv" rev-parse --short main)). Apply them throughout this review:" <<<"$prompt" ||
    fail "the guidelines block does not state its provenance: $prompt"
# Assembly order: preamble, guidelines, scale, manifest.
awk '/VERIFICATION-CHECKPOINT/ { a = NR } /BASE-GUIDELINES-MARKER/ { b = NR } /^Label EVERY finding/ { c = NR } /^Authoritative changed-file manifest/ { d = NR }
    END { exit !(a && b && c && d && a < b && b < c && c < d) }' <<<"$prompt" ||
    fail "prompt is not assembled as preamble, guidelines, scale, manifest: $prompt"

echo "==> --uncommitted reads HEAD's guidelines, --commit the parent's, the default union the merge base's"
out="$(cd "$conv" && ./scripts/codex-review.sh review --uncommitted 2>&1)" || fail "--uncommitted review failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'HEAD-GUIDELINES-MARKER' <<<"$prompt" || fail "--uncommitted did not read HEAD's guidelines: $prompt"
! grep -Fq 'WORKTREE-GUIDELINES-MARKER' <<<"$prompt" || fail "--uncommitted read the working tree's guidelines: $prompt"
out="$(cd "$conv" && ./scripts/codex-review.sh review --commit "$conv_head" 2>&1)" || fail "--commit review failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'BASE-GUIDELINES-MARKER' <<<"$prompt" || fail "--commit did not read the parent's guidelines: $prompt"
! grep -Fq 'HEAD-GUIDELINES-MARKER' <<<"$prompt" || fail "--commit read the reviewed commit's own guidelines: $prompt"
out="$(cd "$conv" && ./scripts/codex-review.sh challenge 2>&1)" || fail "default-scope challenge failed: $out"
grep -q "Reviewing branch changes against main AND uncommitted work" <<<"$out" || fail "default scope did not take both halves: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'BASE-GUIDELINES-MARKER' <<<"$prompt" || fail "the default union did not read the merge base's guidelines: $prompt"
! grep -Fq 'WORKTREE-GUIDELINES-MARKER' <<<"$prompt" || fail "the default union read the working tree's guidelines: $prompt"
: >"$stub_argv"
out="$(cd "$conv" && ./scripts/codex-review.sh review --commit "$conv_base" 2>&1)" || fail "--commit on the root commit failed: $out"
grep -Fq 'no base revision for this scope; built-in instructions only' <<<"$out" || fail "a parentless commit did not fall back to the built-in instructions: $out"
! grep -Fq 'Repository review guidelines' <<<"$(prompt_of "$out")" || fail "a parentless commit still carried guidelines: $out"
[ -s "$stub_argv" ] || fail "codex was not invoked for a genuine root commit"

echo "==> --commit refuses a shallow boundary with unavailable parent history before codex"
shallow="${test_tmp}/guidelines-shallow"
git clone -q --depth 1 --branch feature "file://$conv" "$shallow"
[ "$(git -C "$shallow" rev-parse --is-shallow-repository)" = true ] || fail "the shallow fixture is not shallow"
if git -C "$shallow" cat-file -e "${conv_base}^{commit}" 2>/dev/null; then
    fail "the shallow fixture still has its parent commit"
fi
: >"$stub_argv"
status=0
out="$(cd "$shallow" && ./scripts/codex-review.sh review --commit HEAD 2>&1)" || status=$?
[ "$status" -eq 2 ] || fail "unavailable parent history exited $status instead of 2: $out"
grep -Fq "parent history unavailable at $conv_base" <<<"$out" || fail "the shallow refusal did not identify the unavailable parent: $out"
[ ! -s "$stub_argv" ] || fail "codex was invoked despite unavailable parent history"

echo "==> [review_guidelines].file at the base revision governs: not the branch's table, not the conventional path"
pol="${test_tmp}/guidelines-policied"
guidelines_fixture "$pol"
printf '# BASE-POLICY-MARKER\n' >"$pol/.devflow.toml"
stub_reader "$pol" '{ rigor: { level: "standard" }, review_guidelines: { file: "docs/custom-guidelines.md", text: null, challenge_focus: "CONFIGURED-CHALLENGE-FOCUS", review_focus: "CONFIGURED-REVIEW-FOCUS" } }'
printf 'CUSTOM-GUIDELINES-MARKER\n' >"$pol/docs/custom-guidelines.md"
printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$pol/docs/review-guidelines.md"
git -C "$pol" add -A
git_t -C "$pol" commit -qm 'test: base policy names custom guidelines'
git -C "$pol" checkout -qb feature
printf '# BRANCH-POLICY-MARKER\n' >"$pol/.devflow.toml"
stub_reader "$pol" '{ rigor: { level: "standard" }, review_guidelines: { file: "docs/branch-guidelines.md", text: null, challenge_focus: "BRANCH-FOCUS", review_focus: "BRANCH-FOCUS" } }'
printf 'BRANCH-GUIDELINES-MARKER\n' >"$pol/docs/branch-guidelines.md"
git -C "$pol" add -A
git_t -C "$pol" commit -qm 'test: branch points the table at its own file'
out="$(cd "$pol" && ./scripts/codex-review.sh challenge --base main 2>&1)" || fail "challenge with a configured table failed: $out"
grep -Fq "Review guidelines: docs/custom-guidelines.md at $(git -C "$pol" rev-parse --short main)" <<<"$out" ||
    fail "the run did not name the configured file at the base revision: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'CUSTOM-GUIDELINES-MARKER' <<<"$prompt" || fail "the configured guidelines file is missing from the prompt: $prompt"
! grep -Fq 'CONVENTIONAL-GUIDELINES-MARKER' <<<"$prompt" || fail "the conventional path was used although the table names another file: $prompt"
! grep -Fq 'BRANCH-GUIDELINES-MARKER' <<<"$prompt" || fail "the branch's own table chose the guidelines: $prompt"
grep -Fq 'Default focus from the repository'"'"'s review policy (.devflow.toml [review_guidelines].challenge_focus; weight it heavily): CONFIGURED-CHALLENGE-FOCUS' <<<"$prompt" ||
    fail "the configured challenge focus is missing from a focus-less challenge: $prompt"
! grep -Fq 'CONFIGURED-REVIEW-FOCUS' <<<"$prompt" || fail "the review focus leaked into a challenge: $prompt"
! grep -Fq 'BRANCH-FOCUS' <<<"$prompt" || fail "the branch's focus reached the prompt: $prompt"
out="$(cd "$pol" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with a configured table failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq '[review_guidelines].review_focus; weight it heavily): CONFIGURED-REVIEW-FOCUS' <<<"$prompt" ||
    fail "the configured review focus is missing from a focus-less review: $prompt"
! grep -Fq 'CONFIGURED-CHALLENGE-FOCUS' <<<"$prompt" || fail "the challenge focus leaked into a review: $prompt"

echo "==> CLI focus text outranks the configured default focus"
out="$(cd "$pol" && ./scripts/codex-review.sh review --base main watch the hooks 2>&1)" || fail "review with CLI focus failed: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'Additional focus from the invoker (weight it heavily): watch the hooks' <<<"$prompt" || fail "CLI focus missing: $prompt"
! grep -Fq 'Default focus from the repository' <<<"$prompt" || fail "the configured focus was appended beside the CLI focus: $prompt"
! grep -Fq 'CONFIGURED-REVIEW-FOCUS' <<<"$prompt" || fail "the configured focus text leaked beside the CLI focus: $prompt"

echo "==> [review_guidelines].text is used inline, over the conventional file"
inl="${test_tmp}/guidelines-inline"
guidelines_fixture "$inl"
printf '# BASE-POLICY-MARKER\n' >"$inl/.devflow.toml"
stub_reader "$inl" '{ rigor: { level: "standard" }, review_guidelines: { file: null, text: "INLINE-GUIDELINES-MARKER\nsecond inline line", challenge_focus: null, review_focus: null } }'
printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$inl/docs/review-guidelines.md"
git -C "$inl" add -A
git_t -C "$inl" commit -qm 'test: inline guidelines'
git -C "$inl" checkout -qb feature
printf 'change\n' >"$inl/src.txt"
git -C "$inl" add -A
git_t -C "$inl" commit -qm 'test: work'
out="$(cd "$inl" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with inline guidelines failed: $out"
grep -Fq 'Review guidelines: .devflow.toml [review_guidelines].text at' <<<"$out" || fail "the run did not name the inline source: $out"
prompt="$(prompt_of "$out")"
grep -Fq 'Repository review guidelines (.devflow.toml [review_guidelines].text, read at' <<<"$prompt" || fail "inline guidelines block missing its provenance: $prompt"
grep -Fq 'INLINE-GUIDELINES-MARKER' <<<"$prompt" && grep -Fq 'second inline line' <<<"$prompt" || fail "inline guidelines text missing or truncated: $prompt"
! grep -Fq 'CONVENTIONAL-GUIDELINES-MARKER' <<<"$prompt" || fail "the conventional file was used although text is configured: $prompt"
! grep -Fq 'Default focus' <<<"$prompt" || fail "a null focus produced a default-focus block: $prompt"

echo "==> an absent, incomplete, old, or refusing reader falls back to the conventional path"
for variant in absent incomplete unsupported refusing; do
    fb="${test_tmp}/guidelines-${variant}"
    guidelines_fixture "$fb"
    printf '# BASE-POLICY-MARKER\n' >"$fb/.devflow.toml"
    if [ "$variant" = unsupported ]; then
        stub_reader "$fb" '{ rigor: { level: "standard" } }'
    elif [ "$variant" = incomplete ]; then
        stub_reader "$fb" '{}'
        rm "$fb/scripts/lib/toml-lite.mjs"
    elif [ "$variant" = refusing ]; then
        stub_reader "$fb" '{}'
        printf '# BRANCH-POLICY-MARKER (not the base copy, so the stub refuses with exit 1)\n' >"$fb/.devflow.toml"
    fi
    printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$fb/docs/review-guidelines.md"
    git -C "$fb" add -A
    git_t -C "$fb" commit -qm 'test: base'
    git -C "$fb" checkout -qb feature
    printf 'change\n' >"$fb/src.txt"
    git -C "$fb" add -A
    git_t -C "$fb" commit -qm 'test: work'
    out="$(cd "$fb" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with a ${variant} reader failed: $out"
    if [ "$variant" = refusing ]; then
        grep -Fq 'refused .devflow.toml (exit 1); using the conventional path' <<<"$out" || fail "a refusing reader was not reported: $out"
        grep -Fq 'stub reader: not the base revision policy' <<<"$out" || fail "the stderr of the refusing reader was not surfaced: $out"
    fi
    grep -Fq 'Review guidelines: docs/review-guidelines.md at' <<<"$out" || fail "the ${variant} reader did not fall back to the conventional path: $out"
    grep -Fq 'CONVENTIONAL-GUIDELINES-MARKER' <<<"$(prompt_of "$out")" || fail "conventional guidelines missing after the ${variant} reader: $out"
done

echo "==> a configured file missing at the base revision refuses before codex is invoked"
mis="${test_tmp}/guidelines-missing"
guidelines_fixture "$mis"
printf '# BASE-POLICY-MARKER\n' >"$mis/.devflow.toml"
stub_reader "$mis" '{ rigor: { level: "standard" }, review_guidelines: { file: "docs/nowhere.md", text: null, challenge_focus: null, review_focus: null } }'
git -C "$mis" add -A
git_t -C "$mis" commit -qm 'test: base names a missing file'
git -C "$mis" checkout -qb feature
printf 'change\n' >"$mis/src.txt"
git -C "$mis" add -A
git_t -C "$mis" commit -qm 'test: work'
: >"$stub_argv"
if out="$(cd "$mis" && ./scripts/codex-review.sh review --base main 2>&1)"; then
    fail "a configured guidelines file missing at the base revision was accepted: $out"
fi
grep -Fq "[review_guidelines].file names 'docs/nowhere.md', which does not exist at" <<<"$out" || fail "missing-file refusal did not name the file and revision: $out"
[ ! -s "$stub_argv" ] || fail "codex was invoked despite the missing guidelines file: $(cat "$stub_argv")"

echo "==> symlinks in policy, reader, and guidelines paths refuse before codex"
for path in .devflow.toml scripts/devflow-policy.mjs scripts/lib/toml-lite.mjs \
    docs/custom-guidelines.md docs/review-guidelines.md; do
    fixture="$pol"
    [ "$path" != docs/review-guidelines.md ] || fixture="$conv"
    symlink_repo="${test_tmp}/guidelines-symlink-${path//\//-}"
    git clone -q --branch main "$fixture" "$symlink_repo"
    mv "$symlink_repo/$path" "$symlink_repo/$path.regular"
    ln -s "${path##*/}.regular" "$symlink_repo/$path"
    git -C "$symlink_repo" add -A
    git_t -C "$symlink_repo" commit -qm 'test: base has a symlink instead of a regular file'
    revision="$(git -C "$symlink_repo" rev-parse HEAD)"
    git -C "$symlink_repo" checkout -qb symlink-change
    printf 'candidate change\n' >"$symlink_repo/symlink-change.txt"
    git -C "$symlink_repo" add symlink-change.txt
    git_t -C "$symlink_repo" commit -qm 'test: work after the symlink base'
    : >"$stub_argv"
    status=0
    out="$(cd "$symlink_repo" && ./scripts/codex-review.sh review --base main 2>&1)" || status=$?
    [ "$status" -eq 2 ] || fail "symlink at $path exited $status instead of 2: $out"
    grep -Fq "'$path' at $revision is not a regular file" <<<"$out" ||
        fail "the symlink refusal did not identify $path at $revision: $out"
    [ ! -s "$stub_argv" ] || fail "codex was invoked despite the symlink at $path"
done

echo "==> failed Git tree or existing-blob reads refuse before codex is invoked"
# Keep real repositories and inject only the failed Git operation: a missing
# path has a successful, empty tree lookup, whereas an unavailable object or
# failed lookup must never downgrade the configured instructions to fallback.
mkdir -p "${test_tmp}/object-read-bin"
export OBJECT_READ_REAL_GIT="$(command -v git)"
cat >"${test_tmp}/object-read-bin/git" <<'GITSTUB'
#!/usr/bin/env bash
if [ "$OBJECT_READ_OPERATION" = tree ] && [ "$1" = --literal-pathspecs ] &&
    [ "$2" = ls-tree ] && [ "${@: -1}" = "$OBJECT_READ_PATH" ]; then
    echo "simulated Git tree lookup failure" >&2
    exit 128
fi
if [ "$OBJECT_READ_OPERATION" = blob ] && [ "$1" = show ] &&
    [ "$2" = "$OBJECT_READ_REV:$OBJECT_READ_PATH" ]; then
    echo "simulated Git blob read failure" >&2
    exit 128
fi
exec "$OBJECT_READ_REAL_GIT" "$@"
GITSTUB
chmod +x "${test_tmp}/object-read-bin/git"
for operation in tree blob; do
    for path in .devflow.toml scripts/devflow-policy.mjs scripts/lib/toml-lite.mjs \
        docs/custom-guidelines.md docs/review-guidelines.md; do
        fixture="$pol"
        [ "$path" != docs/review-guidelines.md ] || fixture="$conv"
        revision="$(git -C "$fixture" rev-parse main)"
        : >"$stub_argv"
        status=0
        out="$(cd "$fixture" && PATH="${test_tmp}/object-read-bin:$PATH" \
            OBJECT_READ_OPERATION="$operation" OBJECT_READ_PATH="$path" OBJECT_READ_REV="$revision" \
            ./scripts/codex-review.sh review --base main 2>&1)" || status=$?
        [ "$status" -eq 2 ] || fail "${operation} failure for $path exited $status instead of 2: $out"
        if [ "$operation" = tree ]; then diagnostic=inspect; else diagnostic=read; fi
        grep -Fq "could not $diagnostic '$path' at $revision" <<<"$out" ||
            fail "${operation} refusal did not identify $path at $revision: $out"
        [ ! -s "$stub_argv" ] || fail "codex was invoked despite the ${operation} failure for $path"
    done
done

# The repository's REAL reader, where one is vendored: prove the runner can
# drive it from a base revision. A reader that projects the table must select
# the configured file; one that predates it (an older harmon-devkit pin) must
# leave the conventional path in force. Either is the documented behaviour.
real_reader=""
for candidate in scripts/devflow-policy.mjs \
    ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs \
    .claude/skills/dev-flow-support/assets/devflow-policy.mjs \
    .agents/skills/dev-flow-support/assets/devflow-policy.mjs; do
    if [ -f "${repo}/${candidate}" ] && [ -f "${repo}/${candidate%/*}/lib/toml-lite.mjs" ]; then
        real_reader="$candidate"
        break
    fi
done
if [ -n "$real_reader" ] && [ -f "${repo}/.devflow.toml" ] &&
    grep -q '^file  *= "docs/review-guidelines.md"' "${repo}/.devflow.toml"; then
    echo "==> the vendored policy reader (${real_reader}) is driven from the base revision"
    rr="${test_tmp}/guidelines-real-reader"
    guidelines_fixture "$rr"
    mkdir -p "$rr/${real_reader%/*}/lib"
    cp "${repo}/${real_reader}" "$rr/${real_reader}"
    cp "${repo}/${real_reader%/*}/lib/toml-lite.mjs" "$rr/${real_reader%/*}/lib/"
    sed 's|^file  *= "docs/review-guidelines.md"|file = "docs/custom-guidelines.md"|' "${repo}/.devflow.toml" >"$rr/.devflow.toml"
    printf 'CUSTOM-GUIDELINES-MARKER\n' >"$rr/docs/custom-guidelines.md"
    printf 'CONVENTIONAL-GUIDELINES-MARKER\n' >"$rr/docs/review-guidelines.md"
    git -C "$rr" add -A
    git_t -C "$rr" commit -qm 'test: base with the real reader'
    git -C "$rr" checkout -qb feature
    printf 'change\n' >"$rr/src.txt"
    git -C "$rr" add -A
    git_t -C "$rr" commit -qm 'test: work'
    # Exit 3 (no registry offered, so cross-validation is indeterminate) still
    # prints the projection; capture first so pipefail does not read it as
    # "no projection".
    projection="$(node "${repo}/${real_reader}" resolve --policy "$rr/.devflow.toml" --json 2>/dev/null || true)"
    if grep -q '"review_guidelines"' <<<"$projection"; then
        expect=CUSTOM-GUIDELINES-MARKER
        reject=CONVENTIONAL-GUIDELINES-MARKER
    else
        echo "    (this reader predates [review_guidelines]; expecting the conventional-path fallback)"
        expect=CONVENTIONAL-GUIDELINES-MARKER
        reject=CUSTOM-GUIDELINES-MARKER
    fi
    out="$(cd "$rr" && ./scripts/codex-review.sh review --base main 2>&1)" || fail "review with the real reader failed: $out"
    prompt="$(prompt_of "$out")"
    grep -Fq "$expect" <<<"$prompt" || fail "real reader: expected ${expect} in the prompt: $out"
    ! grep -Fq "$reject" <<<"$prompt" || fail "real reader: ${reject} should not be in the prompt: $out"

    echo "==> a symlinked TMPDIR preserves the base reader's configured guidance and scratch cleanup"
    scratch_parent="${test_tmp}/guidelines-physical-tmp"
    scratch_alias="${test_tmp}/guidelines-symlink-tmp"
    mkdir -p "$scratch_parent"
    ln -s "$scratch_parent" "$scratch_alias"
    : >"$stub_argv"
    out="$(cd "$rr" && TMPDIR="$scratch_alias" ./scripts/codex-review.sh review --base main 2>&1)" ||
        fail "review with a symlinked TMPDIR failed: $out"
    prompt="$(prompt_of "$out")"
    grep -Fq "$expect" <<<"$prompt" || fail "symlinked TMPDIR: expected ${expect} in the prompt: $out"
    ! grep -Fq "$reject" <<<"$prompt" || fail "symlinked TMPDIR: ${reject} should not be in the prompt: $out"
    [ -s "$stub_argv" ] || fail "codex was not invoked with a symlinked TMPDIR"
    [ -z "$(ls -A "$scratch_parent")" ] || fail "review left scratch files in the symlinked TMPDIR"
else
    echo "    (no vendored policy reader beside a shipped [review_guidelines] table; real-reader case skipped)"
fi

echo "==> --base warns when the ref lags an upstream HEAD already contains"
# The reported bug: `--base main` on a checkout whose local main trails
# origin/main reviews the already-merged commits as if this branch introduced
# them, drawing findings against files the branch never touched.
# basestale is pinned at the CURRENT origin/develop and tracks it, so advancing
# the upstream afterwards leaves it behind by exactly the new commits.
git branch -q --track basestale origin/develop
(
    cd "${test_tmp}/upstream"
    echo one >merged-one.txt
    echo two >merged-two.txt
    git add merged-one.txt merged-two.txt
    git_t commit -q -m "upstream work 1" -- merged-one.txt
    git_t commit -q -m "upstream work 2" -- merged-two.txt
)
git fetch -q origin
pre_merge="$(git rev-parse HEAD)"
git_t merge -q --no-edit origin/develop
out="$(run review --base basestale)" || fail "stale-base run exited non-zero (must stay advisory): $out"
# Advisory, not fatal: the review still has to happen, or the warning has
# turned a nudge into a refusal.
grep -q "STUB-ARGS: exec review" "$stub_argv" || fail "stale-base warning suppressed the review: $out"
grep -q "lags its upstream 'origin/develop'" <<<"$out" || fail "stale-base warning missing: $out"
grep -q "contains 2 commits that already merged upstream" <<<"$out" || fail "stale-base warning miscounted the carried commits: $out"
grep -q -- "--base origin/develop" <<<"$out" || fail "stale-base warning does not name the remote-qualified ref: $out"

echo "==> --base warns on a HALF-updated branch, where the upstream tip is not in HEAD"
# Base at A, upstream since advanced A->B->C, HEAD carrying B but not C. The
# upstream tip is NOT an ancestor of HEAD, yet B's already-merged changes sit
# inside basestale...HEAD — so an is-ancestor(upstream, HEAD) trigger goes
# silent on exactly the contamination it exists to catch. The merge bases are
# what differ (A vs B), which is why the check compares those.
git checkout -q -b halfway "$pre_merge"
git_t merge -q --no-edit origin/develop~1
out="$(run review --base basestale)" || fail "half-updated stale-base run exited non-zero: $out"
grep -q "lags its upstream 'origin/develop'" <<<"$out" || fail "no warning on a half-updated branch: $out"
grep -q "contains 1 commit that already merged upstream" <<<"$out" || fail "half-updated warning miscounted (or mis-pluralized) the carried commits: $out"
git checkout -q feature

echo "==> a stale base whose upstream commits are NOT in HEAD stays silent"
# The other side of the merge-base comparison: with nothing of the upstream in
# HEAD both diffs start at the same commit, base...HEAD is already correct, and
# a warning here would be a false positive on a healthy run.
git checkout -q -b prestale "$pre_merge"
out="$(run review --base basestale)" || fail "pre-merge stale-base run exited non-zero: $out"
grep -q "lags its upstream" <<<"$out" && fail "warned on a base whose upstream commits HEAD does not contain: $out"
git checkout -q feature

echo "==> --base refs with no upstream never warn"
# A tag, a raw sha, and a remote-qualified ref have no @{upstream}; each must
# reach the review silently instead of erroring out of the resolution attempt.
git tag basetag basestale
for ref in basetag "$(git rev-parse basestale)" origin/develop; do
    out="$(run review --base "$ref")" || fail "--base '$ref' exited non-zero: $out"
    grep -q "STUB-ARGS: exec review" "$stub_argv" || fail "--base '$ref' did not reach codex: $out"
    grep -q "lags its upstream" <<<"$out" && fail "--base '$ref' has no upstream but warned: $out"
done

echo "==> a tree-neutral upstream gap does not warn"
# The gap is real in commits and empty in content — a file added upstream and
# reverted upstream. base...HEAD and origin/develop...HEAD are then identical,
# so Codex reads the same diff either way and there is nothing to warn about.
# neutralbase is pinned BEFORE the pair lands, so it is genuinely behind.
git branch -q --track neutralbase origin/develop
(
    cd "${test_tmp}/upstream"
    echo scratch >revertme.txt
    git add revertme.txt
    git_t commit -q -m "add revertme"
    git rm -q revertme.txt
    git_t commit -q -m "revert revertme"
)
git fetch -q origin
git checkout -q -b neutral origin/develop
echo n >neutral.txt
git add neutral.txt
git_t commit -q -m "work on top of the tree-neutral gap"
out="$(run review --base neutralbase)" || fail "tree-neutral run exited non-zero: $out"
grep -q "lags its upstream" <<<"$out" && fail "warned on an upstream gap that changes no files: $out"
git checkout -q feature

echo "==> the full-ref spelling of a local branch still warns"
# --base accepts refs/heads/<branch> (rev-parse resolves it), but
# `refs/heads/main@{upstream}` is not an upstream query and simply fails, so
# without normalization this spelling would skip the check silently.
for ref in refs/heads/basestale heads/basestale; do
    out="$(run review --base "$ref")" || fail "--base '$ref' exited non-zero: $out"
    grep -q "lags its upstream 'origin/develop'" <<<"$out" || fail "--base '$ref' skipped the stale-base check: $out"
done

echo "==> commits plus a dirty tree review BOTH halves, in labelled sections"
# The reported bug: the two scopes are disjoint and the dirty tree used to win
# outright, so a re-run after an uncommitted fix reviewed that fix alone and
# banked a clean pass for a fraction of the change. Both halves must be in one
# manifest, and each must land in its own section — a file listed under the
# wrong heading tells the reviewer to collect the wrong diff for it.
echo x >dirty.txt
mkdir newdir
echo y >newdir/inner.txt
out="$(run review)" || fail "commits-plus-dirty review exited non-zero: $out"
grep -q "BOTH parts are in scope" <<<"$out" || fail "commits plus a dirty tree did not select the union scope: $out"
grep -q "uncommitted work in the working tree" <<<"$out" || fail "union scope does not name the worktree half: $out"
grep -q "origin/develop...HEAD" <<<"$out" || fail "union scope does not name the committed half: $out"
committed_half="$(printf '%s\n' "$out" | sed -n '/^Committed changes (git diff/,/^Uncommitted changes (git status/p')"
uncommitted_half="$(printf '%s\n' "$out" | sed -n '/^Uncommitted changes (git status/,$p')"
[ -n "$committed_half" ] || fail "union manifest missing its committed section: $out"
[ -n "$uncommitted_half" ] || fail "union manifest missing its uncommitted section: $out"
grep -q "feature.txt" <<<"$committed_half" || fail "committed half missing the branch's own commit: $out"
grep -q "dirty.txt" <<<"$committed_half" && fail "worktree file filed under the committed heading: $out"
grep -q "dirty.txt" <<<"$uncommitted_half" || fail "untracked file missing from the uncommitted half: $out"
grep -q "newdir/inner.txt" <<<"$uncommitted_half" || fail "file inside untracked dir missing from manifest (collapsed to dir entry): $out"
rm -rf dirty.txt newdir

echo "==> a >200-entry dirty tree still reviews (no SIGPIPE abort) and marks truncation"
# Top-level files: git status collapses an untracked directory into a single
# "?? dir/" entry, which would defeat the >200-entry premise.
i=1
while [ "$i" -le 250 ]; do
    : >"bulk_f${i}.txt"
    i=$((i + 1))
done
out="$(run review)" || fail "large dirty tree aborted the review (pipefail/SIGPIPE regression): $out"
grep -q "STUB-ARGS: exec review" "$stub_argv" || fail "codex not invoked on large dirty tree: $out"
grep -q "manifest truncated at 200 entries" <<<"$out" || fail "truncation marker missing on >200-entry manifest: $out"
rm -f bulk_f*.txt

echo "==> clean tree at the base tip refuses, non-zero, without invoking codex"
git checkout -q -b tipcheck origin/develop
# Non-zero is the point: a capped review loop reads exit status, so a zero
# here would be banked as the clean pass the stage exits on.
if out="$(run review)"; then
    fail "nothing-to-review case exited zero (reads as a clean pass): $out"
fi
grep -q "Nothing to review" <<<"$out" || fail "expected nothing-to-review message: $out"
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite nothing to review: $out"

echo "==> at the base tip, a dirty tree reviews the worktree alone"
# The other side of the union: with no commits beyond the base there is no
# second half, so the split manifest and its headings must not appear.
echo tipwork >tipwork.txt
out="$(run review)" || fail "dirty tree at the base tip exited non-zero: $out"
grep -q "Review the uncommitted work" <<<"$out" || fail "base-tip dirty tree did not select the uncommitted scope: $out"
grep -q "BOTH parts are in scope" <<<"$out" && fail "union scope selected with no commits beyond the base: $out"
grep -q "Committed changes (git diff" <<<"$out" && fail "empty committed half still emitted a manifest section: $out"
grep -q "tipwork.txt" <<<"$out" || fail "worktree file missing from manifest: $out"
rm -f tipwork.txt

echo "==> --base level with its base refuses, non-zero, without invoking codex"
# The reported bug: an explicit --base built an empty manifest and shipped a
# scope string anyway, and Codex's "that diff is empty" reply exited 0 and
# consumed a round of a capped loop.
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite an empty --base diff: $out"
grep -q "Nothing to review" <<<"$out" || fail "missing empty--base refusal message: $out"
grep -q -- "--uncommitted" <<<"$out" || fail "empty --base refusal does not name the fix: $out"

echo "==> --base on a dirty tree says the uncommitted work is out of scope"
echo scratch >scratch.txt
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted on a dirty tree: $out"
fi
grep -q "working tree is dirty" <<<"$out" || fail "no dirty-tree note on --base: $out"
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite an empty --base diff: $out"

echo "==> --uncommitted on a clean tree refuses, non-zero, without invoking codex"
rm -f scratch.txt
if out="$(run review --uncommitted)"; then
    fail "--uncommitted on a clean tree was accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite a clean tree: $out"
grep -q "Nothing to review" <<<"$out" || fail "missing empty--uncommitted refusal message: $out"

echo "==> status.showUntrackedFiles=no cannot hide an untracked-only tree"
# Both the auto dirty-tree test and the --base warning read `git status`; with
# the default untracked mode, this config makes a tree holding only untracked
# work look clean, so the auto path would review the branch instead of the
# work, and --base would skip its warning.
git_t config status.showUntrackedFiles no
echo hidden >hidden.txt
out="$(run review)" || fail "untracked-only tree with showUntrackedFiles=no exited non-zero: $out"
grep -q "uncommitted work" <<<"$out" || fail "untracked-only tree was not seen as dirty: $out"
grep -q "hidden.txt" <<<"$out" || fail "untracked file missing from manifest: $out"
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted: $out"
fi
grep -q "working tree is dirty" <<<"$out" || fail "dirty-tree note suppressed by showUntrackedFiles=no: $out"
rm -f hidden.txt
git_t config --unset status.showUntrackedFiles

echo "==> --commit on an empty commit refuses, non-zero, without invoking codex"
git_t commit -q --allow-empty -m "empty commit"
if out="$(run review --commit HEAD)"; then
    fail "--commit on an empty commit was accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite an empty commit diff: $out"
grep -q "Nothing to review" <<<"$out" || fail "missing empty--commit refusal message: $out"
git_t reset -q --hard HEAD~1

echo "==> bad mode is rejected"
if out="$(run bogus 2>&1)"; then
    fail "bogus mode accepted: $out"
fi

echo "==> invalid explicit targets fail fast without invoking codex"
if out="$(run review --base no-such-ref 2>&1)"; then
    fail "--base with an unresolvable ref was accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite bad --base ref: $out"
grep -q "does not resolve" <<<"$out" || fail "missing fail-fast message for bad --base: $out"
if out="$(run challenge --commit 0000000000000000000000000000000000000000 2>&1)"; then
    fail "--commit with an unresolvable sha was accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite bad --commit sha: $out"

echo "==> conflicting target flags are rejected"
if out="$(run review --base origin/develop --uncommitted 2>&1)"; then
    fail "conflicting target flags accepted (last-wins regression): $out"
fi
grep -q "mutually exclusive" <<<"$out" || fail "missing conflicting-flags message: $out"
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite conflicting flags: $out"

echo "==> --commit manifests cover root and merge commits"
root_sha="$(git rev-list --max-parents=0 HEAD | tail -1)"
out="$(run review --commit "$root_sha")" || fail "root-commit review exited non-zero: $out"
grep -q "codex-review.sh" <<<"$out" || fail "root commit manifest empty (missing --root): $out"
git checkout -q -b mergetest feature
git branch -q sidebr "$root_sha"
git checkout -q sidebr
echo s >side.txt
git add side.txt
git_t commit -q -m side
git checkout -q mergetest
git_t merge -q --no-ff -m merge sidebr >/dev/null 2>&1 || fail "fixture merge failed"
merge_sha="$(git rev-parse HEAD)"
out="$(run review --commit "$merge_sha")" || fail "merge-commit review exited non-zero: $out"
grep -q "side.txt" <<<"$out" || fail "merge commit manifest missing first-parent change: $out"
grep -q "feature.txt" <<<"$out" && fail "merge manifest includes pre-merge mainline files (diff-tree -m regression): $out"

echo "==> a submodule-only change is not misread as empty under diff.ignoreSubmodules=all"
# The empty-scope guard turns "no files changed" into a hard refusal, so a
# config that hides a real change from `git diff` would block a legitimate
# review. Both helpers pass git's defaults explicitly to prevent that.
git init -q "${test_tmp}/submod"
(
    cd "${test_tmp}/submod"
    git_t commit -q --allow-empty -m one
    git_t commit -q --allow-empty -m two
)
git checkout -q -b submodtest feature
# protocol.file.allow: git >=2.38 refuses file:// submodules by default.
git -c protocol.file.allow=always submodule add -q "${test_tmp}/submod" vendored
git_t commit -q -m "add submodule"
submod_base="$(git rev-parse HEAD)"
(cd vendored && git checkout -q HEAD~1)
git add vendored
git_t commit -q -m "bump submodule pointer only"
git_t config diff.ignoreSubmodules all
out="$(run review --base "$submod_base")" || fail "submodule-only diff refused as empty: $out"
grep -q "vendored" <<<"$out" || fail "submodule gitlink missing from manifest: $out"
git_t config --unset diff.ignoreSubmodules

echo "==> a differing-submodule-commit refuses the uncommitted diff"
# Two initialized submodules, the first at a differing commit and the second
# clean. The production fix (refuse_dirty_submodules) captures the complete
# `git submodule status --recursive` output and tests it with a here-string,
# so a SIGPIPE from an early-exiting consumer under pipefail cannot silently
# accept a partial match. A git wrapper emits the real output first, then pads
# with >64 KB of clean entries — grep -q finds the dirty record and exits
# early, the wrapper still has 70 KB to write, and the resulting SIGPIPE under
# pipefail makes the pipeline return 141 instead of 0, so the if-condition in
# refuse_dirty_submodules evaluates false and the dirty state is silently
# accepted. Calls refuse_dirty_submodules directly to isolate the SIGPIPE
# mechanism from unrelated collect_untracked_diff failures (stale untracked
# directories from earlier tests).
sigpipe_real_git="$(command -v git)"
sigpipe_bin="${test_tmp}/sigpipe-bin"
mkdir -p "$sigpipe_bin"
cat >"$sigpipe_bin/git" <<SIGPIPE_WRAPPER
#!/usr/bin/env bash
if [ "\${1:-}" = "submodule" ] && [ "\${2:-}" = "status" ]; then
    "$sigpipe_real_git" "\$@"
    _rc=\$?
    for _i in \$(seq 1 1200); do
        printf ' 0000000000000000000000000000000000000000 padding-submod-%04d\n' "\$_i"
    done
    exit \$_rc
fi
exec "$sigpipe_real_git" "\$@"
SIGPIPE_WRAPPER
chmod +x "$sigpipe_bin/git"
git checkout -q -b submod-refusal-test feature
git init -q "${test_tmp}/submod-a"
(cd "${test_tmp}/submod-a" && git_t commit -q --allow-empty -m a1 && git_t commit -q --allow-empty -m a2)
git init -q "${test_tmp}/submod-b"
(cd "${test_tmp}/submod-b" && git_t commit -q --allow-empty -m b1)
git -c protocol.file.allow=always submodule add -q "${test_tmp}/submod-a" sub-a
git -c protocol.file.allow=always submodule add -q "${test_tmp}/submod-b" sub-b
git_t commit -q -m "add two submodules"
(cd sub-a && git checkout -q HEAD~1)
# sub-a now differs from the index; sub-b is clean. The git wrapper appends
# ~70 KB of clean padding after the real output, so grep -q exits early on the
# dirty record and the writer still has >64 KB to flush — triggering SIGPIPE.
if (
    set -euo pipefail
    export PATH="$sigpipe_bin:$PATH"
    # shellcheck source=scripts/lib/review-scope.sh
    . ./scripts/lib/review-scope.sh
    refuse_dirty_submodules
); then
    fail "a differing-submodule-commit was accepted (SIGPIPE regression)"
fi

echo "==> a clean submodule tree is accepted by refuse_dirty_submodules"
(cd sub-a && git checkout -q -)
if ! (
    set -euo pipefail
    export PATH="$sigpipe_bin:$PATH"
    # shellcheck source=scripts/lib/review-scope.sh
    . ./scripts/lib/review-scope.sh
    refuse_dirty_submodules
); then
    fail "a clean submodule tree was refused by refuse_dirty_submodules"
fi
git checkout -q feature

echo "==> an unresolvable base refuses, on a dirty tree as much as a clean one"
# Degrading to the worktree half would be the original bug in a new place: a
# fraction of the change reviewed, exit 0, and a stage that reads the status
# rather than the warning banks it as a clean pass. Which commits are missing
# is precisely what cannot be determined here, so there is no honest partial
# scope — the refusal names --uncommitted as the deliberate way to ask for one.
norem="${test_tmp}/norem"
mkdir -p "${norem}/scripts"
cp "${repo}/scripts/codex-review.sh" "${norem}/scripts/"
mkdir -p "${norem}/scripts/lib"
cp -R "${repo}/scripts/lib/review-instructions" "${norem}/scripts/lib/"
cp "${repo}/scripts/lib/review-scope.sh" "${norem}/scripts/lib/"
git init -q -b feature "$norem"
(
    cd "$norem"
    git add -A
    git_t commit -q -m base
    if out="$(invoke_review review 2>&1)"; then
        fail "clean tree with no detectable base was accepted: $out"
    fi
    grep -q "Could not resolve a base" <<<"$out" || fail "missing unresolvable-base message: $out"
    grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked with no resolvable base: $out"
    echo loose >loose.txt
    if out="$(invoke_review review 2>&1)"; then
        fail "dirty tree with no detectable base reviewed the worktree alone and exited 0: $out"
    fi
    grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked on a partial scope: $out"
    grep -q -- "--uncommitted" <<<"$out" || fail "refusal does not name the deliberate narrow target: $out"
    # ...and that named escape must actually work, or the refusal is a dead end.
    out="$(invoke_review review --uncommitted 2>&1)" || fail "--uncommitted refused with no base: $out"
    grep -q "loose.txt" <<<"$out" || fail "worktree file missing from --uncommitted manifest: $out"
)

echo "==> a git failure in either half is refused, not read as an empty half"
# Neither half may fail into "". A failed `git diff` with a dirty tree would
# leave the worktree half non-empty, satisfy the non-empty manifest backstop,
# and ship a one-sided review that exits 0 (a partial clone missing objects is
# the realistic trigger); a failed `git status` would read as a clean tree and
# do the same in reverse. The stub fails one subcommand, only when armed, so
# every other git call in the fixture behaves normally.
real_git="$(command -v git)"
cat >"${test_tmp}/bin/git" <<GITSTUB
#!/usr/bin/env bash
# Matched by SCANNING the arguments, not by position: the review path also
# passes --no-ext-diff, and pinning --name-status to \$2 made this stub stop
# intercepting the moment a flag was added ahead of it — the case would then
# pass by never simulating the failure at all.
if [ -n "\${FAIL_GIT_DIFF:-}" ] && [ "\${1:-}" = "diff" ] && grep -Fxq -- --name-status <<<"\$(printf '%s\n' "\$@")"; then
    echo "fatal: simulated missing object" >&2
    exit 128
fi
if [ -n "\${FAIL_GIT_STATUS:-}" ] && [ "\${1:-}" = "status" ]; then
    echo "fatal: simulated unreadable index" >&2
    exit 128
fi
exec "${real_git}" "\$@"
GITSTUB
chmod +x "${test_tmp}/bin/git"
git checkout -q feature
echo halfwork >halfwork.txt
if out="$(FAIL_GIT_DIFF=1 run review)"; then
    fail "an unreadable branch diff was reviewed as an empty half and exited 0: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked with a committed half that could not be read: $out"
grep -q "refusing rather than reading an unreadable" <<<"$out" || fail "missing unreadable-diff refusal message: $out"
if out="$(FAIL_GIT_STATUS=1 run review)"; then
    fail "an unreadable worktree was reviewed as clean and exited 0: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked with a worktree half that could not be read: $out"
grep -q "refusing rather than reading an unreadable worktree" <<<"$out" || fail "missing unreadable-worktree refusal message: $out"
rm -f halfwork.txt "${test_tmp}/bin/git"

# The reported bug: one codex_models_manager decode error inlines the entire
# models JSON as a single ~195 KiB stderr line, and the CLI retries, so eleven
# lines carried 2.1 MB of a 2.2 MB captured log — the verdict a plain `tail`
# should have shown was buried, and `cat`-ing the log to read the findings
# overran an agent's tool-output limit. The bound is on line LENGTH rather than
# on that message, so these guard the class: any future payload dump is covered.
echo bound >bound.txt
big_out="${test_tmp}/bound.out"
big_err="${test_tmp}/bound.err"
longest() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$1"; }

echo "==> an over-long CLI stderr line is bounded, and stdout is left alone"
STUB_BIG_STDERR=40000 invoke_review review --uncommitted >"$big_out" 2>"$big_err" ||
    fail "review with a payload-dumping stub exited non-zero: $(cat "$big_err")"
[ "$(longest "$big_err")" -lt 2000 ] ||
    fail "over-long stderr line was not bounded (longest $(longest "$big_err") bytes)"
grep -q "truncated by codex-review.sh" "$big_err" ||
    fail "no truncation marker, so a reader cannot tell output was dropped"
grep -q "short stderr narration" "$big_err" ||
    fail "bounding the long line also dropped the ordinary narration around it"
# stdout carries the verdict, where a long prose line is legitimate; filtering
# it would corrupt the very output the bound exists to keep readable.
[ "$(longest "$big_out")" -gt 4000 ] ||
    fail "a long stdout line was truncated; only stderr may be bounded"
grep -q "truncated by codex-review.sh" "$big_out" &&
    fail "truncation marker reached stdout; only stderr may be bounded"

echo "==> the stderr filter preserves the CLI's exit status"
# pipefail must surface codex's own status, not the filter's — otherwise a
# failed review reads as the clean pass a capped loop exits on.
status=0
STUB_EXIT=7 STUB_BIG_STDERR=40000 invoke_review review --uncommitted >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "codex exit status lost through the filter (got ${status}, want 7)"

echo "==> CODEX_REVIEW_MAX_STDERR_BYTES=0 restores the unbounded output"
CODEX_REVIEW_MAX_STDERR_BYTES=0 STUB_BIG_STDERR=40000 \
    invoke_review review --uncommitted >/dev/null 2>"$big_err" ||
    fail "review with the bound disabled exited non-zero: $(cat "$big_err")"
[ "$(longest "$big_err")" -gt 40000 ] ||
    fail "escape hatch did not restore the full line (longest $(longest "$big_err") bytes)"

echo "==> a non-numeric bound is refused before the CLI is invoked"
if out="$(CODEX_REVIEW_MAX_STDERR_BYTES=abc invoke_review review --uncommitted 2>&1)"; then
    fail "non-numeric bound accepted: $out"
fi
grep -q "STUB-ARGS" "$stub_argv" && fail "codex invoked despite an invalid bound: $out"
grep -q "must be a non-negative integer" <<<"$out" || fail "missing validation message: $out"

echo "==> a bound past INT64_MAX is refused rather than leaking a shell error"
# All-digit but too wide for `test -eq`, which fails with "integer expression
# expected" ON STDERR and then runs effectively unbounded — a shell error in
# the very stream this change exists to keep clean.
if out="$(CODEX_REVIEW_MAX_STDERR_BYTES=999999999999999999999 invoke_review review --uncommitted 2>&1)"; then
    fail "an INT64_MAX-exceeding bound was accepted: $out"
fi
grep -q "integer expression expected" <<<"$out" && fail "shell arithmetic error leaked to the caller: $out"
grep -q "implausibly large" <<<"$out" || fail "missing implausible-bound message: $out"
# The widest value that still compares cleanly must keep working.
CODEX_REVIEW_MAX_STDERR_BYTES=999999999999999999 STUB_BIG_STDERR=40000 \
    invoke_review review --uncommitted >/dev/null 2>"$big_err" ||
    fail "the widest safe bound was rejected: $(cat "$big_err")"
grep -q "integer expression expected" "$big_err" && fail "shell arithmetic error at the 18-digit boundary: $(cat "$big_err")"
rm -f bound.txt

echo "==> gate: another repo's project-scoped plugin install is not accepted"
fake_claude="${test_tmp}/claude-config"
mkdir -p "${fake_claude}/plugins"
cat >"${fake_claude}/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "codex@openai-codex": [
      {
        "scope": "project",
        "projectPath": "/some/other/repo",
        "installPath": "/nonexistent/plugin/root",
        "version": "1.0.6"
      }
    ]
  }
}
JSON
if out="$( (
    export CLAUDE_CONFIG_DIR="$fake_claude"
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate enable accepted an install scoped to another repo: $out"
fi
grep -q "not installed" <<<"$out" || fail "missing not-installed message for foreign-scoped install: $out"

echo "==> gate: refuses to arm when the companion reports not ready"
fake_plugin="${test_tmp}/fake-plugin"
mkdir -p "${fake_plugin}/scripts" "${fake_claude}2/plugins"
cat >"${fake_plugin}/scripts/codex-companion.mjs" <<'MJS'
const args = process.argv.slice(2);
if (args.includes("--json")) {
  console.log(JSON.stringify({ ready: process.env.FAKE_READY === "true" }));
} else {
  console.log(`companion invoked: ${args.join(" ")}`);
}
MJS
cat >"${fake_claude}2/plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "codex@openai-codex": [
      { "scope": "user", "installPath": "${fake_plugin}", "version": "1.0.6" }
    ]
  }
}
JSON
if out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=false
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate armed despite companion ready:false: $out"
fi
grep -q "not ready" <<<"$out" || fail "missing not-ready refusal message: $out"

echo "==> gate: arms when the companion reports ready"
out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)" ||
    fail "gate enable failed with companion ready:true: $out"
grep -q "companion invoked: setup --enable-review-gate" <<<"$out" || fail "companion toggle not invoked after readiness pass: $out"

echo "==> gate: refuses when the plugin is explicitly disabled in settings"
ws="${test_tmp}/ws"
mkdir -p "${ws}/scripts" "${ws}/.claude"
cp "${repo}/scripts/codex-gate.sh" "${ws}/scripts/"
printf '%s\n' '{ "enabledPlugins": { "codex@openai-codex": false } }' >"${ws}/.claude/settings.local.json"
if out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${ws}/scripts/codex-gate.sh" enable
) 2>&1)"; then
    fail "gate armed despite plugin disabled in settings: $out"
fi
grep -q "explicitly disabled" <<<"$out" || fail "missing disabled-plugin refusal message: $out"

echo "==> gate: status warns that an armed flag is inert when the plugin is disabled"
out="$(
    (
        export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data"
        "${ws}/scripts/codex-gate.sh" status
    ) 2>&1
)" || fail "status exited non-zero in disabled-plugin workspace: $out"
grep -q "INERT" <<<"$out" || fail "status did not flag the inert gate flag: $out"

echo "==> gate: enable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true "${repo}/scripts/codex-gate.sh" enable </dev/null 2>&1)"; then
    fail "non-interactive enable was accepted (silent arming bypass): $out"
fi
grep -q "non-interactive" <<<"$out" || fail "missing non-interactive enable refusal message: $out"

echo "==> gate: disable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" "${repo}/scripts/codex-gate.sh" disable </dev/null 2>&1)"; then
    fail "non-interactive disable was accepted (agent could disarm its own gate): $out"
fi
grep -q "non-interactive" <<<"$out" || fail "missing non-interactive disable refusal message: $out"

# ---------------------------------------------------------------------------
# Envelope mode (harmon-devkit#941): the runner as the producer of exactly one
# validated, immutable pass file — and never of a run.json write.
# ---------------------------------------------------------------------------
env_root="${test_tmp}/envelope"
mkdir -p "${env_root}/bin"
# The envelope stub answers on stdout, as `codex exec review` does, with
# whatever reply the case armed; its narration goes to stderr. STUB_GATE
# parks it mid-review until the gate file appears, which is how the race case
# holds a "timed-out" original open while its retry runs to completion.
cat >"${env_root}/bin/codex" <<'CODEXSTUB'
#!/usr/bin/env bash
printf 'OpenAI Codex (test)\n--------\n' >&2
[ -z "${STUB_EFFORT-high}" ] || printf 'reasoning effort: %s\n' "${STUB_EFFORT-high}" >&2
printf '%s\n' '--------' user >&2
printf 'argv=%s\n' "$*" >>"${STUB_LOG:-/dev/null}"
cd_dir=
while [ $# -gt 0 ]; do
    case "$1" in
    --cd) cd_dir="$2"; shift 2 ;;
    *) shift ;;
    esac
done
cat >"${STUB_PROMPT:-/dev/null}"
printf 'cd=%s\n' "$cd_dir" >>"${STUB_LOG:-/dev/null}"
echo "stub review narration on stderr" >&2
if [ -n "${STUB_GATE:-}" ]; then
    : >"${STUB_GATE}.waiting"
    while [ ! -e "$STUB_GATE" ]; do sleep 0.1; done
fi
[ -z "${STUB_PAYLOAD:-}" ] || cat "$STUB_PAYLOAD"
exit "${STUB_EXIT:-0}"
CODEXSTUB
chmod +x "${env_root}/bin/codex"

git init -q -b main "${env_root}/upstream"
(
    cd "${env_root}/upstream"
    mkdir -p scripts/lib ai/skills/universal
    cp "${repo}/scripts/codex-review.sh" scripts/
    cp "${repo}/scripts/lib/review-scope.sh" "${repo}/scripts/lib/readonly-sandbox.sh" scripts/lib/
    cp -R "${repo}/scripts/lib/review-instructions" scripts/lib/
    cp -R "${repo}/ai/skills/universal/dev-flow-support" ai/skills/universal/
    cp "${repo}/agent-registry.json" .
    git add -A
    git_t commit -q -m base
)
git clone -q "${env_root}/upstream" "${env_root}/clone"
ewd="${env_root}/clone"
git -C "$ewd" checkout -q -b feature
echo change >"${ewd}/feature.txt"
git -C "$ewd" add feature.txt
git_t -C "$ewd" commit -q -m work
env_head="$(git -C "$ewd" rev-parse HEAD)"
env_base="$(git -C "$ewd" rev-parse main)"
record="${env_root}/record"

reset_record() {
    rm -rf "$record"
    mkdir -p "$record"
    printf '{"run_id":"run-941","initiated_by":"human","receipts":[{"kind":"transition","stage":"challenge"}]}\n' >"${record}/run.json"
}

# payload FILE STAGE ROUND FINDER [JQ-FILTER] — a payload that binds the
# fixture's head; the filter bends one field for the refusal cases.
payload() {
    local file="$1" stage="$2" round="$3" finder="$4" filter="${5:-.}"
    jq -n --arg stage "$stage" --argjson round "$round" --arg head "$env_head" --arg finder "$finder" '
        {stage: $stage, round: $round, reviewed_head: $head, finder: $finder, slot: $finder,
         findings: [{id: "\($stage)-r\($round)-\($finder)-1", path: "feature.txt", line: 1,
                     class: "hardening", provenance: "original", fingerprint: "new",
                     priority: "P2", recommended_disposition: "defer", evidence: "stub finding"}],
         counts: {P0: 0, P1: 0, P2: 1, P3: 0}}
        | if $stage == "challenge" then .attack_scenarios = [
            {id: "as-1", description: "stub attack", outcome: "surfaced-finding",
             finding_id: "\($stage)-r\($round)-\($finder)-1"}] else . end' | jq "$filter" >"$file"
}

# envelope_run MODE [ARGS...] — the flags a caller passes, overridable per case.
envelope_run() {
    local mode="$1"
    shift
    local slot=codex-adversarial
    [ "$mode" = review ] && slot=codex-verification
    slot="${ENV_SLOT:-$slot}"
    (cd "$ewd" && PATH="${env_root}/bin:${PATH}" ./scripts/codex-review.sh "$mode" \
        --model gpt-5.6-sol --envelope --run-id "${ENV_RUN_ID:-run-941}" --head "${ENV_HEAD:-$env_head}" \
        --stage "$mode" --round "${ENV_ROUND:-1}" --slot "$slot" \
        --tier frontier --record-dir "$record" "$@" --base main)
}

# Nothing under a .json name and no temporary left behind.
assert_nothing_published() {
    local leftovers
    leftovers="$(find "$record" -mindepth 1 -path "${record}/run.json" -prune -o -type f -print)"
    [ -z "$leftovers" ] || fail "$1 left files behind: $leftovers"
}

echo "==> envelope: a valid challenge pass is bound, validated and published once"
reset_record
run_json_before="$(cat "${record}/run.json")"
payload "${env_root}/p.json" challenge 1 codex-adversarial
out="$(STUB_PAYLOAD="${env_root}/p.json" STUB_LOG="${env_root}/stub.log" STUB_PROMPT="${env_root}/prompt" \
    envelope_run challenge 2>"${env_root}/err")" || fail "valid envelope run failed: $(cat "${env_root}/err")"
pass_file="${record}/passes/challenge-r1-codex-adversarial.json"
[ "$out" = "$pass_file" ] || fail "stdout is not exactly the published path: $out"
[ -f "$pass_file" ] || fail "no pass published"
jq -e --arg h "$env_head" \
    '.role == "challenger" and .status == "completed" and .head == $h and
     .producer == {harness: "codex-cli", model: "gpt-5.6-sol", tier: "frontier"} and
     .run == {run_id: "run-941", initiated_by: "human"} and .payload.slot == "codex-adversarial"' \
    "$pass_file" >/dev/null || fail "published envelope is not bound as captured: $(cat "$pass_file")"
node "${repo}/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" envelope "$pass_file" \
    --run-id run-941 --initiated-by human --known-ids <(echo '[]') --receipt >/dev/null ||
    fail "the published pass does not validate"
[ "$(cat "${record}/run.json")" = "$run_json_before" ] || fail "the runner wrote run.json"
[ "$(find "${record}/passes" -mindepth 1 | wc -l)" -eq 1 ] || fail "temporaries left in passes/: $(ls -A "${record}/passes")"
grep -q "stub review narration" "${env_root}/err" || fail "Codex's narration did not reach stderr"
grep -q "^cd=/" "${env_root}/stub.log" && ! grep -q "^cd=${ewd}\$" "${env_root}/stub.log" ||
    fail "Codex did not review an immutable checkout: $(cat "${env_root}/stub.log")"
# challenge-r4-codex-adversarial-2: envelope mode uses `codex exec review` —
# legacy mode's approval-never invocation — never plain `exec`, which runs
# approval on-request and let an escalated command escape its sandbox.
grep -Eq '^argv=exec --cd /[^ ]+ review --model gpt-5\.6-sol --config model_reasoning_effort=high -$' "${env_root}/stub.log" ||
    fail "envelope mode did not invoke codex exec review: $(cat "${env_root}/stub.log")"
! grep -Eq -- '--output-schema|--output-last-message|--sandbox' "${env_root}/stub.log" ||
    fail "envelope mode still passes the removed plain-exec flags: $(cat "${env_root}/stub.log")"
grep -Fq 'The result.challenger JSON Schema:' "${env_root}/prompt" && grep -Fq '"attack_scenarios"' "${env_root}/prompt" ||
    fail "the payload schema is not requested in the prompt"
grep -q "immutable diff ${env_base}...${env_head}" "${env_root}/prompt" || fail "scope not rewritten to captured SHAs"
grep -q 'challenge-r1-codex-adversarial-1' "${env_root}/prompt" || fail "binding instructions missing from the prompt"

echo "==> envelope effort: metadata lives outside passes and preserves envelope schema"
effort_file="${record}/finder-effort/challenge-r1-codex-adversarial.json"
jq -e '. == {requested: "high", effective: "high", source: "banner", matched: true}' "$effort_file" >/dev/null || fail "missing matched metadata"
[ "$(find "${record}/finder-effort" -type f | wc -l)" -eq 1 ] || fail "metadata temporary remains"

for effort in medium ''; do
    reset_record
    STUB_EFFORT="$effort" STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || fail "default mismatch envelope failed"
    effective="${effort:-unknown}"
    jq -e --arg effective "$effective" '.requested == "high" and .effective == $effective and .matched == false and
        .source == (if $effective == "unknown" then "unknown" else "banner" end)' "$effort_file" >/dev/null || fail "wrong mismatch/unknown metadata"
    [ "$(find "${record}/passes" -type f | wc -l)" -eq 1 ] || fail "metadata appeared in passes"
    reset_record
    rc=0
    STUB_EFFORT="$effort" STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge --require-effort >/dev/null 2>"${env_root}/err" || rc=$?
    [ "$rc" -eq 1 ] || fail "strict envelope mismatch exited $rc"
    grep -q "requested=high effective=$effective" "${env_root}/err" || fail "strict envelope error omits effort"
    assert_nothing_published 'strict effort refusal'
done

echo "==> envelope effort: advisory metadata link failure keeps the published pass"
reset_record
mkdir -p "${record}/finder-effort"
printf 'existing metadata\n' >"$effort_file"
out="$(STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge 2>"${env_root}/err")" ||
    fail "advisory metadata collision failed the pass: $(cat "${env_root}/err")"
[ "$out" = "$pass_file" ] && [ -f "$pass_file" ] || fail "metadata collision lost the published pass/path"
grep -Fq "WARNING: could not publish advisory effort metadata $effort_file" "${env_root}/err" ||
    fail "metadata collision warning does not name the path"
[ "$(cat "$effort_file")" = 'existing metadata' ] || fail "metadata collision overwrote the existing record"
[ "$(find "${record}/passes" -type f | wc -l)" -eq 1 ] || fail "metadata collision left pass temporaries"
[ "$(find "${record}/finder-effort" -type f | wc -l)" -eq 1 ] || fail "metadata collision left effort temporaries"

echo "==> envelope: null optionals in an answer are normalized away, then validated"
reset_record
payload "${env_root}/p.json" challenge 1 codex-adversarial '.substitutes_for = null'
out="$(STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge 2>"${env_root}/err")" ||
    fail "a payload with null optionals was refused: $(cat "${env_root}/err")"
jq -e '.payload | has("substitutes_for") | not' "$out" >/dev/null || fail "a null optional survived normalization"
node "${repo}/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" envelope "$out" \
    --run-id run-941 --initiated-by human --known-ids <(echo '[]') --receipt >/dev/null ||
    fail "the normalized pass does not validate"
reset_record
payload "${env_root}/p.json" challenge 1 codex-adversarial '.counts = null'
rc=0
STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "a null on a REQUIRED key was normalized into acceptance (rc $rc)"
assert_nothing_published "null required key"

echo "==> envelope: review mode publishes a result.reviewer pass"
reset_record
payload "${env_root}/p.json" review 1 codex-verification
STUB_PAYLOAD="${env_root}/p.json" envelope_run review >/dev/null 2>"${env_root}/err" ||
    fail "valid review envelope failed: $(cat "${env_root}/err")"
jq -e '.role == "reviewer"' "${record}/passes/review-r1-codex-verification.json" >/dev/null ||
    fail "review mode did not publish a reviewer envelope"

echo "==> envelope: a run id run.json does not bind is refused before any review"
reset_record
: >"${env_root}/stub.log"
rc=0
ENV_RUN_ID=run-other STUB_PAYLOAD="${env_root}/p.json" STUB_LOG="${env_root}/stub.log" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] || fail "run-id mismatch exited $rc, want 1"
grep -q "does not bind run id" "${env_root}/err" || fail "run-id refusal message missing: $(cat "${env_root}/err")"
[ ! -s "${env_root}/stub.log" ] || fail "Codex ran despite a run-id mismatch"
assert_nothing_published "run-id mismatch"

echo "==> envelope: a head other than HEAD is refused"
reset_record
rc=0
ENV_HEAD="$env_base" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "does not match HEAD" "${env_root}/err" || fail "head mismatch not refused (rc $rc): $(cat "${env_root}/err")"
assert_nothing_published "head mismatch"

echo "==> envelope: a payload bound to another round is refused, nothing partial lands"
reset_record
payload "${env_root}/bad.json" challenge 1 codex-adversarial '.round = 2'
rc=0
STUB_PAYLOAD="${env_root}/bad.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "does not bind the captured" "${env_root}/err" || fail "misbound payload not refused (rc $rc): $(cat "${env_root}/err")"
assert_nothing_published "misbound payload"

echo "==> envelope: a payload failing receipt validation is refused, nothing partial lands"
reset_record
payload "${env_root}/bad.json" challenge 1 codex-adversarial '.counts.P2 = 0'
rc=0
STUB_PAYLOAD="${env_root}/bad.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "failed receipt validation" "${env_root}/err" || fail "invalid payload not refused (rc $rc): $(cat "${env_root}/err")"
assert_nothing_published "invalid payload"

echo "==> envelope: prose instead of one JSON object is refused"
reset_record
printf 'P1 feature.txt:1 — prose, not a payload\n' >"${env_root}/bad.json"
rc=0
STUB_PAYLOAD="${env_root}/bad.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] || fail "prose output not refused (rc $rc)"
assert_nothing_published "prose output"

echo "==> envelope: two JSON objects, or an object inside prose, fail closed"
for shape in two prose; do
    reset_record
    payload "${env_root}/one.json" challenge 1 codex-adversarial
    if [ "$shape" = two ]; then
        cat "${env_root}/one.json" "${env_root}/one.json" >"${env_root}/bad.json"
    else
        {
            echo "Here is the review:"
            cat "${env_root}/one.json"
            echo "Hope this helps."
        } >"${env_root}/bad.json"
    fi
    rc=0
    STUB_PAYLOAD="${env_root}/bad.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
    [ "$rc" -eq 1 ] && grep -q "not exactly one JSON object" "${env_root}/err" ||
        fail "a $shape reply was not refused (rc $rc): $(cat "${env_root}/err")"
    assert_nothing_published "$shape reply"
done

echo "==> envelope: one object in one fenced block, and nothing else, publishes"
reset_record
payload "${env_root}/one.json" challenge 1 codex-adversarial
{
    echo '```json'
    cat "${env_root}/one.json"
    echo '```'
} >"${env_root}/fenced.json"
STUB_PAYLOAD="${env_root}/fenced.json" envelope_run challenge >/dev/null 2>"${env_root}/err" ||
    fail "a single fenced object was refused: $(cat "${env_root}/err")"
[ -f "$pass_file" ] || fail "a single fenced object published nothing"

echo "==> envelope: a failing CLI publishes nothing"
reset_record
rc=0
STUB_EXIT=3 STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 3 ] || fail "CLI failure exited $rc, want 3"
assert_nothing_published "CLI failure"

echo "==> envelope: binding flags without --envelope, or after the target, are refused"
rc=0
(cd "$ewd" && ./scripts/codex-review.sh challenge --run-id run-941 --base main) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a stray --run-id without --envelope exited $rc, want 2"
rc=0
(cd "$ewd" && ./scripts/codex-review.sh challenge --base main --envelope) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "--envelope after the target was read as focus text (rc $rc)"
rc=0
(cd "$ewd" && PATH="${env_root}/bin:${PATH}" ./scripts/codex-review.sh challenge --envelope --run-id run-941 \
    --head "$env_head" --stage challenge --round 1 --slot codex-adversarial \
    --tier frontier --record-dir "$record" --commit "$env_head") >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "envelope mode accepted a non-branch scope (rc $rc)"

echo "==> envelope: an existing pass is never overwritten"
reset_record
payload "${env_root}/p.json" challenge 1 codex-adversarial
STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>&1 || fail "first publication failed"
before="$(cat "$pass_file")"
payload "${env_root}/p2.json" challenge 1 codex-adversarial '.findings[0].evidence = "second"'
rc=0
STUB_PAYLOAD="${env_root}/p2.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "already exists" "${env_root}/err" || fail "republication not refused (rc $rc): $(cat "${env_root}/err")"
[ "$(cat "$pass_file")" = "$before" ] || fail "an existing pass was rewritten"

echo "==> envelope: a timed-out original cannot clobber its retry's published pass"
# The original passes every up-front check, then stalls inside the review. The
# retry runs to completion and publishes. When the original finally answers,
# only the atomic link stands between it and the retry's receipted evidence.
reset_record
payload "${env_root}/orig.json" challenge 1 codex-adversarial '.findings[0].evidence = "original"'
payload "${env_root}/retry.json" challenge 1 codex-adversarial '.findings[0].evidence = "retry"'
gate="${env_root}/gate"
rm -f "$gate" "${gate}.waiting"
STUB_EFFORT=medium STUB_GATE="$gate" STUB_PAYLOAD="${env_root}/orig.json" envelope_run challenge >"${env_root}/orig.out" 2>"${env_root}/orig.err" &
orig_pid=$!
for _ in $(seq 1 300); do
    [ -e "${gate}.waiting" ] && break
    sleep 0.1
done
[ -e "${gate}.waiting" ] || fail "the original never reached its review"
STUB_PAYLOAD="${env_root}/retry.json" envelope_run challenge >/dev/null 2>"${env_root}/err" ||
    fail "the retry failed: $(cat "${env_root}/err")"
retry_bytes="$(cat "$pass_file")"
: >"$gate"
rc=0
wait "$orig_pid" || rc=$?
[ "$rc" -eq 1 ] && grep -q "never overwritten" "${env_root}/orig.err" ||
    fail "the late original was not refused at publication (rc $rc): $(cat "${env_root}/orig.err")"
[ "$(cat "$pass_file")" = "$retry_bytes" ] && jq -e '.payload.findings[0].evidence == "retry"' "$pass_file" >/dev/null ||
    fail "the late original replaced the retry's pass"
jq -e ' .effective == "high" and .matched == true' "$effort_file" >/dev/null || fail "late original replaced retry effort"
[ "$(find "${record}/passes" -mindepth 1 | wc -l)" -eq 1 ] || fail "the race left temporaries: $(ls -A "${record}/passes")"

echo "==> envelope: a change to any governing input is refused"
# Envelope mode reads its governing inputs from this checkout, so a branch
# editing one would govern its own pass. The invariant (integration-r3,
# restructured from r1/r2's enumerated paths): the registry, the policy, and
# the WHOLE dev-flow-support package at every root the runner can load it
# from — a reader file, a non-reader file such as a schema, and a vendored
# root alike.
for governing in agent-registry.json .devflow.toml \
    ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs \
    ai/skills/universal/dev-flow-support/assets/schemas/result.challenger.schema.json \
    .claude/skills/dev-flow-support/assets/vendored-marker.txt; do
    reset_record
    git -C "$ewd" checkout -q -b governing-edit
    mkdir -p "$(dirname "${ewd}/${governing}")"
    printf '\n' >>"${ewd}/${governing}"
    git -C "$ewd" add "$governing"
    git_t -C "$ewd" commit -q -m "edit $governing"
    rc=0
    STUB_PAYLOAD="${env_root}/p.json" ENV_HEAD="$(git -C "$ewd" rev-parse HEAD)" \
        envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
    git -C "$ewd" checkout -q feature
    git -C "$ewd" branch -q -D governing-edit
    [ "$rc" -eq 1 ] && grep -q "cannot review a change to them" "${env_root}/err" ||
        fail "an edit to $governing was not refused (rc $rc): $(cat "${env_root}/err")"
    assert_nothing_published "$governing edit"
done

echo "==> envelope: grafts are refused and replace refs are ignored on the proof path"
# integration-r1-codex-cloud-3. A graft file is a refusal outright.
reset_record
grafts="$(git -C "$ewd" rev-parse --path-format=absolute --git-path info/grafts)"
mkdir -p "$(dirname "$grafts")"
printf '%s\n' "$env_head" >"$grafts"
rc=0
STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
rm -f "$grafts"
[ "$rc" -eq 1 ] && grep -q "info/grafts exists" "${env_root}/err" ||
    fail "a graft file did not refuse envelope mode (rc $rc): $(cat "${env_root}/err")"
assert_nothing_published "grafts"
# A replace ref substituting the head with a decoy must not change what is
# reviewed: the manifest still names the real change, never the decoy's.
reset_record
decoy="$(git_t -C "$ewd" commit-tree -p "$env_base" -m decoy \
    "$(printf '100644 blob %s\tdecoy.txt\n' "$(echo decoy | git -C "$ewd" hash-object -w --stdin)" | git -C "$ewd" mktree)")"
git -C "$ewd" replace "$env_head" "$decoy"
payload "${env_root}/p.json" challenge 1 codex-adversarial
rc=0
STUB_PAYLOAD="${env_root}/p.json" STUB_PROMPT="${env_root}/prompt" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
git -C "$ewd" replace -d "$env_head" >/dev/null
[ "$rc" -eq 0 ] || fail "envelope mode failed under a replace ref (rc $rc): $(cat "${env_root}/err")"
grep -q 'feature.txt' "${env_root}/prompt" && ! grep -q 'decoy.txt' "${env_root}/prompt" ||
    fail "a replace ref changed the reviewed manifest"

echo "==> envelope: a receipted pass whose file is missing fails closed"
# review-r1-codex-verification-1: its ids are reserved, so dropping it from
# the known-ids set would let this pass reuse one.
reset_record
jq '.receipts += [{kind: "pass", file: "challenge-r1-copilot-adversarial"}]' "${record}/run.json" >"${env_root}/run.json"
mv "${env_root}/run.json" "${record}/run.json"
payload "${env_root}/p.json" challenge 1 codex-adversarial
rc=0
STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "does not exist" "${env_root}/err" ||
    fail "a receipted-but-missing pass did not fail closed (rc $rc): $(cat "${env_root}/err")"
assert_nothing_published "receipted-but-missing pass"

echo "==> envelope: only RECEIPTED passes reserve finding ids; an orphan does not"
# One finder filling two slots of a round (its own, and another primary's as
# a fallback) is the one way two passes can mint the same finding id.
reset_record
payload "${env_root}/p.json" challenge 1 codex-adversarial
STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>&1 || fail "own-slot publication failed"
payload "${env_root}/sub.json" challenge 1 codex-adversarial '.slot = "copilot-adversarial" | .substitutes_for = "copilot-adversarial"'
sub_pass="${record}/passes/challenge-r1-copilot-adversarial.json"
ENV_SLOT=copilot-adversarial STUB_PAYLOAD="${env_root}/sub.json" envelope_run challenge >/dev/null 2>"${env_root}/err" ||
    fail "an orphan's ids were treated as reserved: $(cat "${env_root}/err")"
jq -e '.payload.substitutes_for == "copilot-adversarial"' "$sub_pass" >/dev/null || fail "fallback pass lost substitutes_for"
rm -f "$sub_pass"
jq '.receipts += [{kind: "pass", file: "challenge-r1-codex-adversarial"}]' "${record}/run.json" >"${env_root}/run.json"
mv "${env_root}/run.json" "${record}/run.json"
rc=0
ENV_SLOT=copilot-adversarial STUB_PAYLOAD="${env_root}/sub.json" envelope_run challenge >/dev/null 2>"${env_root}/err" || rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$sub_pass" ] || fail "a receipted pass's finding id was reusable (rc $rc)"

echo "==> envelope: a runner-published pass flows through receipt, verification, adjudication and exit"
# The envelope-mode MECHANISM end to end, with a stub standing in for a
# finder that answers in the payload schema: the runner publishes, the CALLER
# appends the receipt and runs verification, adjudicates, and persists the
# exit verdict. This is not evidence that a Codex lane produces passes today:
# the real CLI fails closed in envelope mode (harmon-devkit#1365), and Codex
# slots are assembled by the role agents.
reset_record
payload "${env_root}/p.json" challenge 1 codex-adversarial
STUB_PAYLOAD="${env_root}/p.json" envelope_run challenge >/dev/null 2>"${env_root}/err" ||
    fail "e2e publication failed: $(cat "${env_root}/err")"
jq '.receipts += [{kind: "pass", file: "challenge-r1-codex-adversarial"}]' "${record}/run.json" >"${env_root}/run.json"
mv "${env_root}/run.json" "${record}/run.json"
sed -e 's/"codex-cli"/"codex-adversarial"/' -e 's/"gemini-cli"/"codex-verification"/' \
    "${repo}/ai/schemas/fixtures/exit/challenger-schema-pass-accepted/policy.toml" >"${env_root}/policy.toml"
exit_cmd=(node "${repo}/ai/skills/universal/dev-flow-support/assets/dev-flow-exit.mjs" --run "$record"
    --stage challenge --policy "${env_root}/policy.toml" --current-head "$env_head" --json)
"${exit_cmd[@]}" --verification-only >"${env_root}/verify.json" 2>"${env_root}/err" ||
    fail "verification failed: $(cat "${env_root}/err") $(cat "${env_root}/verify.json")"
jq -e '.action == "adjudicate"' "${env_root}/verify.json" >/dev/null ||
    fail "verification did not authorize adjudication: $(cat "${env_root}/verify.json")"
mkdir -p "${record}/adjudications"
jq -n --arg head "$env_head" '{schema: 2, run_id: "run-941", stage: "challenge", round: 1, reviewed_head: $head,
    adjudications: [{finding_id: "challenge-r1-codex-adversarial-1", reviewer_priority: "P2",
      adjudicated_priority: "P2", disposition: "fix", reason: "confirmed", evidence: "stub", override: null}]}' \
    >"${record}/adjudications/challenge-r1.json"
"${exit_cmd[@]}" >"${record}/verdict.json" 2>"${env_root}/err" ||
    fail "exit computation failed: $(cat "${env_root}/err") $(cat "${record}/verdict.json")"
jq -e '.outcome' "${record}/verdict.json" >/dev/null || fail "verdict.json has no outcome: $(cat "${record}/verdict.json")"
jq -e '[.diagnostics[]? | select(.level == "reject")] | length == 0' "${record}/verdict.json" >/dev/null ||
    fail "the exit computation rejected the runner's pass: $(cat "${record}/verdict.json")"

# One P2-only round under a cap of 3: the stage continues to round 2.
jq -e '.outcome == "continue" and .action == "dispatch"' "${record}/verdict.json" >/dev/null ||
    fail "unexpected verdict for a P2-only first round: $(cat "${record}/verdict.json")"
node "${repo}/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" adjudication \
    "${record}/adjudications/challenge-r1.json" --pass "$pass_file" --known-adjudicated <(echo '[]') \
    --run-id run-941 --initiated-by human --receipt >/dev/null ||
    fail "the adjudication does not validate against the runner's pass"

echo "codex-review envelope mode OK (20 cases)"

echo "codex-review + codex-gate guards OK (38 cases)"
