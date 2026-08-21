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
# change. Run via `task test:codex-review`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# Stub codex: print the invocation so assertions can grep it. STUB_BIG_STDERR
# and STUB_EXIT arm the payload-dump reproduction and a failing CLI; both are
# off unless set, so every other test sees the plain stub.
mkdir -p "${test_tmp}/bin"
cat >"${test_tmp}/bin/codex" <<'CODEXSTUB'
#!/usr/bin/env bash
printf 'STUB-ARGS:'
printf ' %s' "$@"
printf '\n'
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
    mkdir scripts
    cp "${repo}/scripts/codex-review.sh" scripts/
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

run() {
    ./scripts/codex-review.sh "$@" 2>&1
}

echo "==> clean tree, no local main/master: falls back to origin/HEAD's branch"
out="$(run challenge)" || fail "challenge exited non-zero: $out"
echo "$out" | grep -q "STUB-ARGS: exec review" || fail "codex exec review not invoked: $out"
echo "$out" | grep -q -- "--model gpt-5.6-sol" || fail "review model is not pinned to gpt-5.6-sol: $out"
echo "$out" | grep -q -- "--config model_reasoning_effort=high" || fail "review reasoning is not pinned high: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "remote-qualified fallback base missing: $out"
echo "$out" | grep -q "ADVERSARIAL" || fail "challenge mode instructions missing: $out"
echo "$out" | grep -q "feature.txt" || fail "changed-file manifest missing from branch-scope prompt: $out"
# A clean tree has no second half, so the split manifest must not appear —
# otherwise the union headers would be noise the reviewer has to interpret.
echo "$out" | grep -q "Uncommitted changes (git status" && fail "clean tree emitted an uncommitted manifest section: $out"
# The gate is only meaningful if the scale it gates on is defined in the
# prompt — Codex's own priority labels are an undocumented convention.
echo "$out" | grep -q "Only P0 and P1 decide" || fail "challenge prompt missing the P0/P1 gating rule: $out"
echo "$out" | grep -q "Still report P2s" || fail "challenge prompt missing the report-P2s instruction: $out"
# An unreported P2 never reaches the PR body, so the handoff clause is what
# makes "reported but non-gating" different from "ignored".
echo "$out" | grep -q "carried into the pull request description" || fail "challenge prompt missing the P2 handoff clause: $out"
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

echo "$out" | grep -q "P3 — cosmetic" || fail "challenge prompt missing the P3 level: $out"
echo "$out" | grep -q "adjudicated as at least a P2" || fail "challenge prompt missing the off-scale badge floor: $out"
echo "$out" | grep -q "hypothesis the" ||
    fail "challenge prompt missing the label-is-a-hypothesis rule — an under-labelled P3 could be dropped without adjudication (harmon-init#923 shepherd r2): $out"
! echo "$out" | grep -q "not carried into the pull request description" ||
    fail "challenge prompt still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge: $out"

echo "==> origin/HEAD outranks a stray local main"
git branch -q main "$(git rev-list --max-parents=0 HEAD)"
out="$(run challenge)" || fail "challenge with stray local main exited non-zero: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "stray local main hijacked base detection: $out"
git branch -q -D main

echo "==> --base with no merge base fails fast"
unrelated="$(git_t commit-tree "$(git mktree </dev/null)" -m orphan)"
if out="$(run review --base "$unrelated" 2>&1)"; then
    fail "--base with unrelated history accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite no merge base: $out"
echo "$out" | grep -q "no merge base" || fail "missing no-merge-base message: $out"

echo "==> explicit --base and focus text reach the prompt"
out="$(run review --base origin/develop watch the hooks)" || fail "review --base exited non-zero: $out"
echo "$out" | grep -q "base branch 'origin/develop'" || fail "--base not honored: $out"
echo "$out" | grep -q "VERIFICATION-CHECKPOINT" || fail "review mode instructions missing: $out"
echo "$out" | grep -q "watch the hooks" || fail "focus text missing from prompt: $out"
echo "$out" | grep -q "Only P0 and P1 decide" || fail "review prompt missing the P0/P1 gating rule: $out"
echo "$out" | grep -q "carried into the pull request description" || fail "review prompt missing the P2 handoff clause: $out"
echo "$out" | grep -q "P3 — cosmetic" || fail "review prompt missing the P3 level: $out"
echo "$out" | grep -q "adjudicated as at least a P2" || fail "review prompt missing the off-scale badge floor: $out"
echo "$out" | grep -q "hypothesis the" ||
    fail "review prompt missing the label-is-a-hypothesis rule — an under-labelled P3 could be dropped without adjudication (harmon-init#923 shepherd r2): $out"
! echo "$out" | grep -q "not carried into the pull request description" ||
    fail "review prompt still claims a P3 is never deferred — deferral is decided by adjudication, not by the badge: $out"

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
echo "$out" | grep -q "STUB-ARGS: exec review" || fail "stale-base warning suppressed the review: $out"
echo "$out" | grep -q "lags its upstream 'origin/develop'" || fail "stale-base warning missing: $out"
echo "$out" | grep -q "contains 2 commits that already merged upstream" || fail "stale-base warning miscounted the carried commits: $out"
echo "$out" | grep -q -- "--base origin/develop" || fail "stale-base warning does not name the remote-qualified ref: $out"

echo "==> --base warns on a HALF-updated branch, where the upstream tip is not in HEAD"
# Base at A, upstream since advanced A->B->C, HEAD carrying B but not C. The
# upstream tip is NOT an ancestor of HEAD, yet B's already-merged changes sit
# inside basestale...HEAD — so an is-ancestor(upstream, HEAD) trigger goes
# silent on exactly the contamination it exists to catch. The merge bases are
# what differ (A vs B), which is why the check compares those.
git checkout -q -b halfway "$pre_merge"
git_t merge -q --no-edit origin/develop~1
out="$(run review --base basestale)" || fail "half-updated stale-base run exited non-zero: $out"
echo "$out" | grep -q "lags its upstream 'origin/develop'" || fail "no warning on a half-updated branch: $out"
echo "$out" | grep -q "contains 1 commit that already merged upstream" || fail "half-updated warning miscounted (or mis-pluralized) the carried commits: $out"
git checkout -q feature

echo "==> a stale base whose upstream commits are NOT in HEAD stays silent"
# The other side of the merge-base comparison: with nothing of the upstream in
# HEAD both diffs start at the same commit, base...HEAD is already correct, and
# a warning here would be a false positive on a healthy run.
git checkout -q -b prestale "$pre_merge"
out="$(run review --base basestale)" || fail "pre-merge stale-base run exited non-zero: $out"
echo "$out" | grep -q "lags its upstream" && fail "warned on a base whose upstream commits HEAD does not contain: $out"
git checkout -q feature

echo "==> --base refs with no upstream never warn"
# A tag, a raw sha, and a remote-qualified ref have no @{upstream}; each must
# reach the review silently instead of erroring out of the resolution attempt.
git tag basetag basestale
for ref in basetag "$(git rev-parse basestale)" origin/develop; do
    out="$(run review --base "$ref")" || fail "--base '$ref' exited non-zero: $out"
    echo "$out" | grep -q "STUB-ARGS: exec review" || fail "--base '$ref' did not reach codex: $out"
    echo "$out" | grep -q "lags its upstream" && fail "--base '$ref' has no upstream but warned: $out"
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
echo "$out" | grep -q "lags its upstream" && fail "warned on an upstream gap that changes no files: $out"
git checkout -q feature

echo "==> the full-ref spelling of a local branch still warns"
# --base accepts refs/heads/<branch> (rev-parse resolves it), but
# `refs/heads/main@{upstream}` is not an upstream query and simply fails, so
# without normalization this spelling would skip the check silently.
for ref in refs/heads/basestale heads/basestale; do
    out="$(run review --base "$ref")" || fail "--base '$ref' exited non-zero: $out"
    echo "$out" | grep -q "lags its upstream 'origin/develop'" || fail "--base '$ref' skipped the stale-base check: $out"
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
echo "$out" | grep -q "BOTH parts are in scope" || fail "commits plus a dirty tree did not select the union scope: $out"
echo "$out" | grep -q "uncommitted work in the working tree" || fail "union scope does not name the worktree half: $out"
echo "$out" | grep -q "origin/develop...HEAD" || fail "union scope does not name the committed half: $out"
committed_half="$(printf '%s\n' "$out" | sed -n '/^Committed changes (git diff/,/^Uncommitted changes (git status/p')"
uncommitted_half="$(printf '%s\n' "$out" | sed -n '/^Uncommitted changes (git status/,$p')"
[ -n "$committed_half" ] || fail "union manifest missing its committed section: $out"
[ -n "$uncommitted_half" ] || fail "union manifest missing its uncommitted section: $out"
echo "$committed_half" | grep -q "feature.txt" || fail "committed half missing the branch's own commit: $out"
echo "$committed_half" | grep -q "dirty.txt" && fail "worktree file filed under the committed heading: $out"
echo "$uncommitted_half" | grep -q "dirty.txt" || fail "untracked file missing from the uncommitted half: $out"
echo "$uncommitted_half" | grep -q "newdir/inner.txt" || fail "file inside untracked dir missing from manifest (collapsed to dir entry): $out"
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
echo "$out" | grep -q "STUB-ARGS: exec review" || fail "codex not invoked on large dirty tree: $out"
echo "$out" | grep -q "manifest truncated at 200 entries" || fail "truncation marker missing on >200-entry manifest: $out"
rm -f bulk_f*.txt

echo "==> clean tree at the base tip refuses, non-zero, without invoking codex"
git checkout -q -b tipcheck origin/develop
# Non-zero is the point: a capped review loop reads exit status, so a zero
# here would be banked as the clean pass the stage exits on.
if out="$(run review)"; then
    fail "nothing-to-review case exited zero (reads as a clean pass): $out"
fi
echo "$out" | grep -q "Nothing to review" || fail "expected nothing-to-review message: $out"
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite nothing to review: $out"

echo "==> at the base tip, a dirty tree reviews the worktree alone"
# The other side of the union: with no commits beyond the base there is no
# second half, so the split manifest and its headings must not appear.
echo tipwork >tipwork.txt
out="$(run review)" || fail "dirty tree at the base tip exited non-zero: $out"
echo "$out" | grep -q "Review the uncommitted work" || fail "base-tip dirty tree did not select the uncommitted scope: $out"
echo "$out" | grep -q "BOTH parts are in scope" && fail "union scope selected with no commits beyond the base: $out"
echo "$out" | grep -q "Committed changes (git diff" && fail "empty committed half still emitted a manifest section: $out"
echo "$out" | grep -q "tipwork.txt" || fail "worktree file missing from manifest: $out"
rm -f tipwork.txt

echo "==> --base level with its base refuses, non-zero, without invoking codex"
# The reported bug: an explicit --base built an empty manifest and shipped a
# scope string anyway, and Codex's "that diff is empty" reply exited 0 and
# consumed a round of a capped loop.
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite an empty --base diff: $out"
echo "$out" | grep -q "Nothing to review" || fail "missing empty--base refusal message: $out"
echo "$out" | grep -q -- "--uncommitted" || fail "empty --base refusal does not name the fix: $out"

echo "==> --base on a dirty tree says the uncommitted work is out of scope"
echo scratch >scratch.txt
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted on a dirty tree: $out"
fi
echo "$out" | grep -q "working tree is dirty" || fail "no dirty-tree note on --base: $out"
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite an empty --base diff: $out"

echo "==> --uncommitted on a clean tree refuses, non-zero, without invoking codex"
rm -f scratch.txt
if out="$(run review --uncommitted)"; then
    fail "--uncommitted on a clean tree was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite a clean tree: $out"
echo "$out" | grep -q "Nothing to review" || fail "missing empty--uncommitted refusal message: $out"

echo "==> status.showUntrackedFiles=no cannot hide an untracked-only tree"
# Both the auto dirty-tree test and the --base warning read `git status`; with
# the default untracked mode, this config makes a tree holding only untracked
# work look clean, so the auto path would review the branch instead of the
# work, and --base would skip its warning.
git_t config status.showUntrackedFiles no
echo hidden >hidden.txt
out="$(run review)" || fail "untracked-only tree with showUntrackedFiles=no exited non-zero: $out"
echo "$out" | grep -q "uncommitted work" || fail "untracked-only tree was not seen as dirty: $out"
echo "$out" | grep -q "hidden.txt" || fail "untracked file missing from manifest: $out"
if out="$(run challenge --base origin/develop)"; then
    fail "--base with an empty diff was accepted: $out"
fi
echo "$out" | grep -q "working tree is dirty" || fail "dirty-tree note suppressed by showUntrackedFiles=no: $out"
rm -f hidden.txt
git_t config --unset status.showUntrackedFiles

echo "==> --commit on an empty commit refuses, non-zero, without invoking codex"
git_t commit -q --allow-empty -m "empty commit"
if out="$(run review --commit HEAD)"; then
    fail "--commit on an empty commit was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite an empty commit diff: $out"
echo "$out" | grep -q "Nothing to review" || fail "missing empty--commit refusal message: $out"
git_t reset -q --hard HEAD~1

echo "==> bad mode is rejected"
if out="$(run bogus 2>&1)"; then
    fail "bogus mode accepted: $out"
fi

echo "==> invalid explicit targets fail fast without invoking codex"
if out="$(run review --base no-such-ref 2>&1)"; then
    fail "--base with an unresolvable ref was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite bad --base ref: $out"
echo "$out" | grep -q "does not resolve" || fail "missing fail-fast message for bad --base: $out"
if out="$(run challenge --commit 0000000000000000000000000000000000000000 2>&1)"; then
    fail "--commit with an unresolvable sha was accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite bad --commit sha: $out"

echo "==> conflicting target flags are rejected"
if out="$(run review --base origin/develop --uncommitted 2>&1)"; then
    fail "conflicting target flags accepted (last-wins regression): $out"
fi
echo "$out" | grep -q "mutually exclusive" || fail "missing conflicting-flags message: $out"
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite conflicting flags: $out"

echo "==> --commit manifests cover root and merge commits"
root_sha="$(git rev-list --max-parents=0 HEAD | tail -1)"
out="$(run review --commit "$root_sha")" || fail "root-commit review exited non-zero: $out"
echo "$out" | grep -q "codex-review.sh" || fail "root commit manifest empty (missing --root): $out"
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
echo "$out" | grep -q "side.txt" || fail "merge commit manifest missing first-parent change: $out"
echo "$out" | grep -q "feature.txt" && fail "merge manifest includes pre-merge mainline files (diff-tree -m regression): $out"

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
echo "$out" | grep -q "vendored" || fail "submodule gitlink missing from manifest: $out"
git_t config --unset diff.ignoreSubmodules

echo "==> an unresolvable base refuses, on a dirty tree as much as a clean one"
# Degrading to the worktree half would be the original bug in a new place: a
# fraction of the change reviewed, exit 0, and a stage that reads the status
# rather than the warning banks it as a clean pass. Which commits are missing
# is precisely what cannot be determined here, so there is no honest partial
# scope — the refusal names --uncommitted as the deliberate way to ask for one.
norem="${test_tmp}/norem"
mkdir -p "${norem}/scripts"
cp "${repo}/scripts/codex-review.sh" "${norem}/scripts/"
git init -q -b feature "$norem"
(
    cd "$norem"
    git add -A
    git_t commit -q -m base
    if out="$(./scripts/codex-review.sh review 2>&1)"; then
        fail "clean tree with no detectable base was accepted: $out"
    fi
    echo "$out" | grep -q "Could not resolve a base" || fail "missing unresolvable-base message: $out"
    echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked with no resolvable base: $out"
    echo loose >loose.txt
    if out="$(./scripts/codex-review.sh review 2>&1)"; then
        fail "dirty tree with no detectable base reviewed the worktree alone and exited 0: $out"
    fi
    echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked on a partial scope: $out"
    echo "$out" | grep -q -- "--uncommitted" || fail "refusal does not name the deliberate narrow target: $out"
    # ...and that named escape must actually work, or the refusal is a dead end.
    out="$(./scripts/codex-review.sh review --uncommitted 2>&1)" || fail "--uncommitted refused with no base: $out"
    echo "$out" | grep -q "loose.txt" || fail "worktree file missing from --uncommitted manifest: $out"
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
if [ -n "\${FAIL_GIT_DIFF:-}" ] && [ "\${1:-}" = "diff" ] && [ "\${2:-}" = "--name-status" ]; then
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
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked with a committed half that could not be read: $out"
echo "$out" | grep -q "refusing rather than reading an unreadable" || fail "missing unreadable-diff refusal message: $out"
if out="$(FAIL_GIT_STATUS=1 run review)"; then
    fail "an unreadable worktree was reviewed as clean and exited 0: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked with a worktree half that could not be read: $out"
echo "$out" | grep -q "refusing rather than reading an unreadable worktree" || fail "missing unreadable-worktree refusal message: $out"
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
STUB_BIG_STDERR=40000 ./scripts/codex-review.sh review --uncommitted >"$big_out" 2>"$big_err" ||
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
STUB_EXIT=7 STUB_BIG_STDERR=40000 ./scripts/codex-review.sh review --uncommitted >/dev/null 2>&1 || status=$?
[ "$status" -eq 7 ] || fail "codex exit status lost through the filter (got ${status}, want 7)"

echo "==> CODEX_REVIEW_MAX_STDERR_BYTES=0 restores the unbounded output"
CODEX_REVIEW_MAX_STDERR_BYTES=0 STUB_BIG_STDERR=40000 \
    ./scripts/codex-review.sh review --uncommitted >/dev/null 2>"$big_err" ||
    fail "review with the bound disabled exited non-zero: $(cat "$big_err")"
[ "$(longest "$big_err")" -gt 40000 ] ||
    fail "escape hatch did not restore the full line (longest $(longest "$big_err") bytes)"

echo "==> a non-numeric bound is refused before the CLI is invoked"
if out="$(CODEX_REVIEW_MAX_STDERR_BYTES=abc ./scripts/codex-review.sh review --uncommitted 2>&1)"; then
    fail "non-numeric bound accepted: $out"
fi
echo "$out" | grep -q "STUB-ARGS" && fail "codex invoked despite an invalid bound: $out"
echo "$out" | grep -q "must be a non-negative integer" || fail "missing validation message: $out"

echo "==> a bound past INT64_MAX is refused rather than leaking a shell error"
# All-digit but too wide for `test -eq`, which fails with "integer expression
# expected" ON STDERR and then runs effectively unbounded — a shell error in
# the very stream this change exists to keep clean.
if out="$(CODEX_REVIEW_MAX_STDERR_BYTES=999999999999999999999 ./scripts/codex-review.sh review --uncommitted 2>&1)"; then
    fail "an INT64_MAX-exceeding bound was accepted: $out"
fi
echo "$out" | grep -q "integer expression expected" && fail "shell arithmetic error leaked to the caller: $out"
echo "$out" | grep -q "implausibly large" || fail "missing implausible-bound message: $out"
# The widest value that still compares cleanly must keep working.
CODEX_REVIEW_MAX_STDERR_BYTES=999999999999999999 STUB_BIG_STDERR=40000 \
    ./scripts/codex-review.sh review --uncommitted >/dev/null 2>"$big_err" ||
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
echo "$out" | grep -q "not installed" || fail "missing not-installed message for foreign-scoped install: $out"

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
echo "$out" | grep -q "not ready" || fail "missing not-ready refusal message: $out"

echo "==> gate: arms when the companion reports ready"
out="$( (
    export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true
    run_tty "${repo}/scripts/codex-gate.sh" enable
) 2>&1)" ||
    fail "gate enable failed with companion ready:true: $out"
echo "$out" | grep -q "companion invoked: setup --enable-review-gate" || fail "companion toggle not invoked after readiness pass: $out"

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
echo "$out" | grep -q "explicitly disabled" || fail "missing disabled-plugin refusal message: $out"

echo "==> gate: status warns that an armed flag is inert when the plugin is disabled"
out="$(
    (
        export CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data"
        "${ws}/scripts/codex-gate.sh" status
    ) 2>&1
)" || fail "status exited non-zero in disabled-plugin workspace: $out"
echo "$out" | grep -q "INERT" || fail "status did not flag the inert gate flag: $out"

echo "==> gate: enable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" FAKE_READY=true "${repo}/scripts/codex-gate.sh" enable </dev/null 2>&1)"; then
    fail "non-interactive enable was accepted (silent arming bypass): $out"
fi
echo "$out" | grep -q "non-interactive" || fail "missing non-interactive enable refusal message: $out"

echo "==> gate: disable refuses in a non-interactive shell"
if out="$(CLAUDE_CONFIG_DIR="${fake_claude}2" CLAUDE_PLUGIN_DATA="${test_tmp}/plugin-data" "${repo}/scripts/codex-gate.sh" disable </dev/null 2>&1)"; then
    fail "non-interactive disable was accepted (agent could disarm its own gate): $out"
fi
echo "$out" | grep -q "non-interactive" || fail "missing non-interactive disable refusal message: $out"

echo "codex-review + codex-gate guards OK (38 cases)"
