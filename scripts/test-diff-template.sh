#!/usr/bin/env bash
# Regression tests for the audit's deliberately limited OWNED evaluator.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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

cat >"$source/copier.yml" <<'YAML'
_subdirectory: template
_skip_if_exists: ["docs/**/ ", repo-owned.txt]
YAML
refused "pattern ending in '/**/' is not supported"

cat >"$source/copier.yml" <<'YAML'
_subdirectory: template
_skip_if_exists: ["docs/* ", repo-owned.txt]
YAML
refused "pattern ending in '/*' is not supported"

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

# --- Index states the staged probe cannot compare (issue 401) ----------------
# Real Git index states, never mocked: a conflicted path, a staged blob missing
# from the object store, and `git add -N` placeholders. Each worktree copy
# matches the render, so the worktree comparison alone would call it clean and
# only the index decides the verdict. The template from the last case above is
# reused as is (committed, nothing new to commit).
indexed="$tmp/indexed"
mkdir -p "$indexed/docs/nested"
git init -q "$indexed"
git -C "$indexed" config user.name Fixture
git -C "$indexed" config user.email fixture@example.invalid
git -C "$indexed" config merge.conflictStyle merge
printf '_commit: %s\n' "$(git -C "$source" rev-parse HEAD)" >"$indexed/.copier-answers.yml"
printf 'template\n' >"$indexed/docs/direct.txt"
printf 'template\n' >"$indexed/repo-owned.txt"
# docs/nested/deep.txt stays OUT of HEAD so the intent-to-add cases can stage a
# path the repo has never committed.
git -C "$indexed" add .copier-answers.yml docs/direct.txt repo-owned.txt
git -C "$indexed" commit -qm 'test: rendered baseline'
default_branch="$(git -C "$indexed" branch --show-current)"
baseline="$(git -C "$indexed" rev-parse HEAD)"
audit_indexed() {
    audit_rc=0
    audit_out="$(HARMON_INIT="$source" bash "$assets/diff-template.sh" "$indexed" 2>&1)" || audit_rc=$?
}
reset_indexed() {
    git -C "$indexed" merge --abort 2>/dev/null || true
    # Index from HEAD first: `checkout` and `reset --hard` both choke on an
    # index entry whose blob the unreadable case deleted.
    git -C "$indexed" read-tree HEAD
    git -C "$indexed" checkout -q "$default_branch"
    # Back to the rendered baseline, not merely HEAD: the conflict case commits.
    git -C "$indexed" reset -q --hard "$baseline"
    rm -f "$indexed/docs/nested/deep.txt"
    git -C "$indexed" rm -q --cached --ignore-unmatch -- docs/nested/deep.txt
    printf 'template\n' >"$indexed/docs/nested/deep.txt"
}
reset_indexed

# Positive control: the baseline really is clean, so every exit below is the
# index state's doing.
audit_indexed
[ "$audit_rc" -eq 0 ] || fail "clean indexed baseline returned $audit_rc: $audit_out"

# Unmerged: a real conflict on docs/direct.txt, its worktree copy then set back
# to the render while the index still holds stages 1-3. Before the fix
# `cat-file -e ":path"` failed, the probe read "no staged divergence", exit 0.
git -C "$indexed" checkout -q -b side
printf 'side\n' >"$indexed/docs/direct.txt"
git -C "$indexed" commit -qam 'test: side edit'
git -C "$indexed" checkout -q "$default_branch"
printf 'mainline\n' >"$indexed/docs/direct.txt"
git -C "$indexed" commit -qam 'test: mainline edit'
if git -C "$indexed" merge -q side >/dev/null 2>&1; then
    fail 'fixture merge did not conflict'
fi
[ -n "$(git -C "$indexed" ls-files -u -- docs/direct.txt)" ] || fail 'fixture left no unmerged entry'
printf 'template\n' >"$indexed/docs/direct.txt"
audit_indexed
[ "$audit_rc" -eq 2 ] || fail "unmerged entry with a matching worktree returned $audit_rc: $audit_out"
grep -Fq "'docs/direct.txt' has an unmerged (conflicted) index entry" <<<"$audit_out" ||
    fail "unmerged entry gave no diagnostic: $audit_out"
# The same conflict with the worktree copy deleted reaches the index through
# repo_variant, inside a command substitution, and read as plain MISSING.
rm -f "$indexed/docs/direct.txt"
audit_indexed
[ "$audit_rc" -eq 2 ] || fail "unmerged entry with no worktree copy returned $audit_rc: $audit_out"
grep -Fq 'unmerged (conflicted) index entry' <<<"$audit_out" ||
    fail "unmerged entry without a worktree copy gave no diagnostic: $audit_out"
reset_indexed
git -C "$indexed" branch -q -D side

# Unreadable: divergent bytes staged, their loose object then deleted, the
# worktree restored to the render. `ls-files` still lists the entry, so the
# path looked present while its staged bytes were never compared.
printf 'staged-only bytes for issue 401\n' >"$indexed/docs/direct.txt"
git -C "$indexed" add docs/direct.txt
lost_blob="$(git -C "$indexed" rev-parse :docs/direct.txt)"
lost_object="$(git -C "$indexed" rev-parse --git-path "objects/${lost_blob:0:2}/${lost_blob:2}")"
case "$lost_object" in /*) ;; *) lost_object="$indexed/$lost_object" ;; esac
[ -f "$lost_object" ] || fail "fixture blob is not a loose object: $lost_object"
rm -f "$lost_object"
git -C "$indexed" cat-file -e "$lost_blob" 2>/dev/null && fail 'fixture blob is still readable'
printf 'template\n' >"$indexed/docs/direct.txt"
audit_indexed
[ "$audit_rc" -eq 2 ] || fail "unreadable staged blob returned $audit_rc: $audit_out"
grep -Fq "the staged blob for 'docs/direct.txt' ($lost_blob) is not readable" <<<"$audit_out" ||
    fail "unreadable staged blob gave no diagnostic: $audit_out"
reset_indexed

# Intent-to-add over a worktree copy that matches the render: the placeholder's
# empty blob is not staged content. Before the fix this was a gating
# "staged content differs" line with nothing staged.
git -C "$indexed" add -N docs/nested/deep.txt
[ -n "$(git -C "$indexed" ls-files -s -- docs/nested/deep.txt)" ] || fail 'fixture has no intent-to-add entry'
audit_indexed
[ "$audit_rc" -eq 0 ] || fail "intent-to-add entry returned $audit_rc: $audit_out"
if grep -Fq 'staged content differs' <<<"$audit_out"; then
    fail "intent-to-add entry produced a staged-content finding: $audit_out"
fi
# With its worktree copy gone the path is genuinely absent: plain MISSING, not
# an empty "staged" snapshot compared against the render.
rm -f "$indexed/docs/nested/deep.txt"
audit_indexed
[ "$audit_rc" -eq 1 ] || fail "intent-to-add entry without a worktree copy returned $audit_rc: $audit_out"
grep -Fq 'MISSING  docs/nested/deep.txt  (template ships it' <<<"$audit_out" ||
    fail "absent intent-to-add path was not plain MISSING: $audit_out"
if grep -Fq 'staged content differs' <<<"$audit_out"; then
    fail "absent intent-to-add path produced a staged-content finding: $audit_out"
fi
reset_indexed
# An intent-to-add placeholder standing over a path still in HEAD: the next
# commit deletes it, exactly as `git status` reports, so it is a staged removal.
git -C "$indexed" rm -q --cached docs/direct.txt
git -C "$indexed" add -N docs/direct.txt
audit_indexed
[ "$audit_rc" -eq 1 ] || fail "intent-to-add over a HEAD path returned $audit_rc: $audit_out"
grep -Fq 'MISSING  docs/direct.txt  (tracked in HEAD but staged for removal' <<<"$audit_out" ||
    fail "intent-to-add over a HEAD path was not a staged removal: $audit_out"
reset_indexed

# Negative control for the intent-to-add test: a GENUINELY staged empty file
# holds the same empty blob, and it is real staged content that still gates.
: >"$indexed/docs/nested/deep.txt"
git -C "$indexed" add docs/nested/deep.txt
printf 'template\n' >"$indexed/docs/nested/deep.txt"
audit_indexed
[ "$audit_rc" -eq 1 ] || fail "staged empty file returned $audit_rc: $audit_out"
grep -Fq 'DRIFT    docs/nested/deep.txt  (uncurated — staged content differs' <<<"$audit_out" ||
    fail "staged empty file lost its staged-content finding: $audit_out"
reset_indexed

# A probe that fails AFTER the preflight passed. index_variant re-reads the
# entry inside `$( )`, where it cannot exit, and reading that failure as "no
# index entry" let a tracked, disabled .coderabbit.yaml whose worktree copy is
# gone print the expected ABSENT and exit 0. A `git` shim ahead of the real one
# fails only the Nth exact `ls-files -s -z -- <path>` read of one path: read 1
# is require_index_entries_for's preflight, read 2 is index_variant's.
shim="$tmp/git-shim"
mkdir -p "$shim"
real_git="$(command -v git)"
cat >"$shim/git" <<SHIM
#!/usr/bin/env bash
case " \$* " in
*" ls-files -s -z -- \$FAULT_PATH ")
    n=\$((\$(cat "\$FAULT_COUNT" 2>/dev/null || echo 0) + 1))
    echo "\$n" >"\$FAULT_COUNT"
    if [ "\$n" -eq "\$FAULT_AT" ]; then
        echo 'shim: injected ls-files failure' >&2
        exit 2
    fi
    ;;
esac
exec "$real_git" "\$@"
SHIM
chmod +x "$shim/git"
audit_faulted() { # <path> <failing read number>
    rm -f "$tmp/fault-count"
    audit_rc=0
    audit_out="$(PATH="$shim:$PATH" FAULT_PATH="$1" FAULT_AT="$2" FAULT_COUNT="$tmp/fault-count" \
        HARMON_INIT="$source" bash "$assets/diff-template.sh" "$indexed" 2>&1)" || audit_rc=$?
    fault_reads="$(cat "$tmp/fault-count" 2>/dev/null || echo 0)"
}
printf 'reviews: {}\n' >"$indexed/.coderabbit.yaml"
git -C "$indexed" add .coderabbit.yaml
git -C "$indexed" commit -qm 'test: tracked coderabbit config'
rm -f "$indexed/.coderabbit.yaml"
# Control: unfaulted, the index copy is found and the disabled config gates.
audit_faulted .coderabbit.yaml 0
[ "$audit_rc" -eq 1 ] || fail "unfaulted tracked .coderabbit.yaml returned $audit_rc: $audit_out"
grep -Fq 'DRIFT    .coderabbit.yaml  (CodeRabbit is disabled' <<<"$audit_out" ||
    fail "unfaulted tracked .coderabbit.yaml did not gate: $audit_out"
[ "$fault_reads" -ge 2 ] || fail "shim saw $fault_reads reads of .coderabbit.yaml; the fixture no longer reaches index_variant"
audit_faulted .coderabbit.yaml 2
[ "$audit_rc" -eq 2 ] || fail "failed index_variant read returned $audit_rc: $audit_out"
grep -Fq "FAIL: cannot evaluate the index entry for '.coderabbit.yaml' (ls-files exit 2)" <<<"$audit_out" ||
    fail "failed index_variant read gave no diagnostic: $audit_out"
if grep -Fq 'ABSENT   .coderabbit.yaml' <<<"$audit_out"; then
    fail "failed index_variant read reported the expected ABSENT: $audit_out"
fi
# The same failure on an ordinary rendered path read as plain MISSING.
reset_indexed
rm -f "$indexed/docs/direct.txt"
audit_faulted docs/direct.txt 2
[ "$audit_rc" -eq 2 ] || fail "failed index read of a deleted rendered path returned $audit_rc: $audit_out"
grep -Fq "FAIL: cannot evaluate the index entry for 'docs/direct.txt' (ls-files exit 2)" <<<"$audit_out" ||
    fail "failed index read of a deleted rendered path gave no diagnostic: $audit_out"
reset_indexed
echo 'PASS: unmerged and unreadable index entries exit 2; intent-to-add placeholders carry no staged content'
echo 'PASS: an index read that fails after the preflight exits 2 instead of reading as absent'
