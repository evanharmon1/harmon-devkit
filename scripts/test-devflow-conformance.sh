#!/usr/bin/env bash
# test-devflow-conformance.sh — run harmon-init's portable `.devflow.toml` v2
# conformance corpus against the policy reader this repository vendors as a
# skill asset (ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs).
#
# Why (harmon-devkit#1248): the vendored reader and harmon-init's
# scripts/devflow-policy.mjs are sibling forks — devkit keeps per-run finder
# selection, the vendored-layout --closure probe, and the pin audit's
# migration message, which harmon-init's reader lacks — so the two FILES are
# not byte-identical (convergence is tracked by evanharmon1/harmon-init#1484).
# What IS shared, byte for byte, is the corpus and the runner that drives it.
# Passing that corpus is the contract that the tier resolution (the derived
# Tier, the pin, the `adaptive` retirement, the absent-policy fallback)
# answers here exactly as it does in harmon-init.
#
# The vendored inputs from harmon-init SOURCE_REV below (the registry stays
# pinned to REGISTRY_SOURCE_REV; its later diff only removes label metadata):
#   ai/skills/universal/dev-flow-support/assets/.devflow-conformance-v2.json
#                                         ← .devflow-conformance-v2.json
#   scripts/test-devflow-conformance.py   ← scripts/test-devflow-conformance.py
#   ai/schemas/fixtures/devflow-conformance/policy.toml
#                                         ← .devflow.toml (the corpus's base
#                                           policy; its replacements are
#                                           written against these exact bytes)
#   ai/schemas/fixtures/devflow-conformance/agent-registry.json
#                                         ← agent-registry.json
# Each is checked against its recorded git blob id first, so a hand edit to
# any of them fails here instead of quietly redefining the contract. To
# re-vendor, copy the four files from a newer harmon-init revision and update
# SOURCE_REV (and REGISTRY_SOURCE_REV when applicable) and the blob ids
# together. To confirm a harmon-init RELEASE still carries these bytes (the human follow-up on harmon-init#1464):
#   for p in .devflow-conformance-v2.json scripts/test-devflow-conformance.py \
#       .devflow.toml agent-registry.json; do
#       git -C <harmon-init checkout> rev-parse "<tag>:$p"; done
# and compare with the ids below.
#
# The fixture task-targets.json is devkit's own: the runner resolves with
# --taskfile-dir, and the corpus's base policy names these gate and local
# finder targets. They are stubbed in a scratch Taskfile so the result never
# depends on this repository's real Taskfile.
#
# A mutation control runs last: a copy of the reader that ignores an honored
# pin must make the corpus FAIL, proving the runner actually exercises the
# tier rungs rather than passing on output it never inspects.
#
# Run via `task test:devflow-conformance`. Needs node, python3, and task.
set -euo pipefail

SOURCE_REV="f93e0c2614f9e59c5031d5ac0f3c05bb989d5ca4"
REGISTRY_SOURCE_REV="81bbe78784c0b146e754e80030274ff95e10cf51"
CORPUS_BLOB="3b2fc854eaac0002d81bf4576afe7f716ec85bd7"
RUNNER_BLOB="bbe218be11ff87181fba20f164804870f28420c7"
POLICY_BLOB="7e36129a43e0ae73c8a8c878e6055fdab8a1e6ab"
REGISTRY_BLOB="27844622efb4a7f8508729e6b413170b67bd7b3f"

# Resolved from this script's own location, not the caller's directory.
repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
support="$repo_root/ai/skills/universal/dev-flow-support/assets"
fixtures="$repo_root/ai/schemas/fixtures/devflow-conformance"
corpus="$support/.devflow-conformance-v2.json"
runner="$repo_root/scripts/test-devflow-conformance.py"

fail=0
err() {
    echo "  ✗ $*" >&2
    fail=1
}

for tool in node python3 task; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "test-devflow-conformance: $tool is required" >&2
        exit 1
    }
done

echo "==> vendored inputs match harmon-init ${SOURCE_REV:0:8}"
check_blob() {
    local file="$1" want="$2" source_rev="${3:-$SOURCE_REV}" got
    if [ ! -f "$file" ]; then
        err "${file#"$repo_root"/} is missing"
        return 0
    fi
    got="$(git hash-object -- "$file")"
    if [ "$got" = "$want" ]; then
        echo "  ✓ ${file#"$repo_root"/}"
    else
        err "${file#"$repo_root"/} is blob $got, expected $want (harmon-init ${source_rev:0:8}) — re-vendor it, never hand-edit it"
    fi
    return 0
}
check_blob "$corpus" "$CORPUS_BLOB"
check_blob "$runner" "$RUNNER_BLOB"
check_blob "$fixtures/policy.toml" "$POLICY_BLOB"
check_blob "$fixtures/agent-registry.json" "$REGISTRY_BLOB" "$REGISTRY_SOURCE_REV"
[ "$fail" -eq 0 ] || exit 1

scratch="$(mktemp -d "${TMPDIR:-/tmp}/devflow-conformance.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# make_repo DIR READER — the layout the runner expects: the reader at
# scripts/devflow-policy.mjs beside its lib/, the base policy, the registry,
# and a Taskfile declaring exactly the fixture's target names.
make_repo() {
    local dir="$1" reader="$2"
    mkdir -p "$dir/scripts/lib"
    cp "$reader" "$dir/scripts/devflow-policy.mjs"
    cp "$support/lib/toml-lite.mjs" "$dir/scripts/lib/toml-lite.mjs"
    cp "$fixtures/policy.toml" "$dir/.devflow.toml"
    cp "$fixtures/agent-registry.json" "$dir/agent-registry.json"
    node -e '
const targets = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const lines = ["version: \"3\"", "", "tasks:"];
for (const t of targets) lines.push(`  "${t}":`, "    desc: conformance stub", "    cmds: [\"true\"]");
process.stdout.write(lines.join("\n") + "\n");
' "$fixtures/task-targets.json" >"$dir/Taskfile.yml"
}

# The corpus drives the CLI, whose usage pre-check runs before the library.
# Keep the canonical library invariant covered for non-CLI consumers too.
echo "==> absent merge-base policy requires a branch policy in the library"
if node --input-type=module - "$support/devflow-policy.mjs" <<'JS'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const { resolvePolicy, PolicyError } = await import(pathToFileURL(process.argv[2]));
for (const doc of [null, undefined]) {
    assert.throws(() => resolvePolicy(doc, { mergeBasePolicyAbsent: true }), PolicyError);
}
JS
then
    echo "  ✓ library refuses an absent branch policy"
else
    err "resolvePolicy accepted an absent merge-base policy without a branch policy"
fi

# With the absent-base flag the candidate is validated under the requested
# selections, as on the present-base path: a broken selected table is an
# ordinary invalid-policy exit 1 with a reader diagnostic, never an uncaught
# exception (review round 1, harmon-devkit#1264 port).
echo "==> absent merge-base policy validates the candidate under the requested rigor"
make_repo "$scratch/absent" "$support/devflow-policy.mjs"
# The built-in fallback accepts only rigor "standard", so the candidate's
# default must differ from it for the selected table to go unchecked.
sed -e 's/^default_rigor    = "standard"$/default_rigor    = "thorough"/' \
    -e 's/^rounds            = "standard"$/rounds            = "no-such-rounds"/' \
    "$fixtures/policy.toml" >"$scratch/absent/.devflow.toml"
set +e
(cd "$scratch/absent" && node scripts/devflow-policy.mjs resolve --policy .devflow.toml \
    --merge-base-policy-absent --merge-base-registry agent-registry.json \
    --registry agent-registry.json \
    --taskfile-dir . --rigor standard --json >/dev/null 2>"$scratch/absent.err")
status=$?
set -e
if [ "$status" -eq 1 ] && grep -q '^devflow-policy: ' "$scratch/absent.err" &&
    ! grep -q '^    at ' "$scratch/absent.err"; then
    echo "  ✓ broken selected table is an invalid-policy exit 1"
else
    err "absent-base resolve with a broken selected table exited $status: $(head -2 "$scratch/absent.err")"
fi

# Under the absent-base flag only --merge-base-registry governs: the branch's
# own --registry must never satisfy governance cross-validation (Codex cloud
# review cycle 1 on #1343, finding 4).
echo "==> absent merge-base policy routes governance to --merge-base-registry only"
make_repo "$scratch/route" "$support/devflow-policy.mjs"
set +e
(cd "$scratch/route" && node scripts/devflow-policy.mjs resolve --policy .devflow.toml \
    --merge-base-policy-absent --registry agent-registry.json --taskfile-dir . --json \
    >"$scratch/route-branch.json" 2>/dev/null)
branch_only=$?
(cd "$scratch/route" && node scripts/devflow-policy.mjs resolve --policy .devflow.toml \
    --merge-base-policy-absent --registry agent-registry.json \
    --merge-base-registry agent-registry.json --taskfile-dir . --json \
    >/dev/null 2>/dev/null)
with_base=$?
set -e
if [ "$branch_only" -eq 3 ] && grep -q 'no registry was supplied' "$scratch/route-branch.json" &&
    [ "$with_base" -eq 0 ]; then
    echo "  ✓ the branch registry never satisfies governance cross-validation"
else
    err "registry routing under the absent flag: branch-only exit $branch_only, with merge-base registry exit $with_base"
fi

# A --closure reader written before the flag (one that accepts any option)
# would drop it and let the branch policy govern; delegation must refuse
# instead (Codex cloud review cycle 1 on #1343, finding 1).
echo "==> --closure refuses a reader that predates --merge-base-policy-absent"
mkdir -p "$scratch/oldclosure"
printf '%s\n' 'process.stdout.write("OLD-READER-RAN\n");' >"$scratch/oldclosure/devflow-policy.mjs"
set +e
node "$support/devflow-policy.mjs" resolve --closure "$scratch/oldclosure" --policy "$fixtures/policy.toml" \
    --merge-base-policy-absent --json >"$scratch/oldclosure.out" 2>"$scratch/oldclosure.err"
old_status=$?
set -e
if [ "$old_status" -eq 1 ] && grep -Fq 'predates --merge-base-policy-absent' "$scratch/oldclosure.err" &&
    ! grep -Fq 'OLD-READER-RAN' "$scratch/oldclosure.out"; then
    echo "  ✓ delegation refuses a reader that would drop the flag"
else
    err "--closure delegated --merge-base-policy-absent to a reader that predates it (exit $old_status)"
fi

# The merge-base argument checks run BEFORE --closure delegation in both
# entrypoints (harmon-devkit#1345, review round 1): an older closure would skip
# them, so an empty --merge-base-policy must be refused before it can run. The
# stub closures accept anything and announce themselves if they run.
echo "==> merge-base argument checks run before --closure delegation"
mkdir -p "$scratch/anyclosure"
printf '%s\n' 'process.stdout.write("STUB-CLOSURE-RAN\n");' >"$scratch/anyclosure/devflow-policy.mjs"
printf '%s\n' 'process.stdout.write("STUB-CLOSURE-RAN\n");' >"$scratch/anyclosure/dev-flow-exit.mjs"
set +e
node "$support/devflow-policy.mjs" resolve --closure "$scratch/anyclosure" --policy "$fixtures/policy.toml" \
    --merge-base-policy "" --json >"$scratch/early-reader.out" 2>"$scratch/early-reader.err"
reader_status=$?
node "$support/dev-flow-exit.mjs" --closure "$scratch/anyclosure" --run "$scratch" --stage review \
    --policy "$fixtures/policy.toml" --merge-base-policy "" --json >"$scratch/early-exit.out" 2>"$scratch/early-exit.err"
exit_status=$?
set -e
if [ "$reader_status" -eq 2 ] && grep -Fq -- '--merge-base-policy must be a non-empty file path' "$scratch/early-reader.err" &&
    ! grep -Fq STUB-CLOSURE-RAN "$scratch/early-reader.out"; then
    echo "  ✓ the reader refuses an empty --merge-base-policy before delegating"
else
    err "the reader delegated an empty --merge-base-policy to its --closure (exit $reader_status)"
fi
if [ "$exit_status" -eq 1 ] && grep -Fq -- '--merge-base-policy must be a non-empty file path' "$scratch/early-exit.err" &&
    ! grep -Fq STUB-CLOSURE-RAN "$scratch/early-exit.out"; then
    echo "  ✓ the exit engine refuses an empty --merge-base-policy before delegating"
else
    err "the exit engine delegated an empty --merge-base-policy to its --closure (exit $exit_status)"
fi

# The library refuses an absent merge base that also supplies a merge-base
# document, with otherwise valid v2 documents (finding 6).
echo "==> library refuses an absent merge base together with mergeBaseDoc"
if node --input-type=module - "$support/devflow-policy.mjs" "$support/lib/toml-lite.mjs" "$fixtures/policy.toml" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { resolvePolicy, PolicyError } = await import(pathToFileURL(process.argv[2]));
const { parseToml } = await import(pathToFileURL(process.argv[3]));
const doc = parseToml(readFileSync(process.argv[4], "utf8"));
assert.doesNotThrow(() => resolvePolicy(doc, { mergeBasePolicyAbsent: true }));
assert.throws(() => resolvePolicy(doc, { mergeBasePolicyAbsent: true, mergeBaseDoc: doc }), PolicyError);
JS
then
    echo "  ✓ library refuses mergeBasePolicyAbsent with mergeBaseDoc"
else
    err "resolvePolicy accepted mergeBasePolicyAbsent together with a mergeBaseDoc"
fi

# A trusted caller that runs a merge-base reader DIRECTLY (dev-flow-support's
# step 0, /integrate's merge-base recipe) never goes through --closure, so the
# reader's own probe cannot see it. Both recipes decide the governing argument
# with lib/merge-base-policy.sh (harmon-devkit#1345, criteria 1, 2 and 4); the
# caller below mirrors their code exactly: the merge base's helper (or an
# operator pin when the merge base predates it), then the one-word answer
# turned into an argument array, then the reader.
echo "==> trusted callers carry an absent merge-base policy"
helper="$support/lib/merge-base-policy.sh"
mbrepo="$scratch/mbrepo"
make_repo "$mbrepo" "$support/devflow-policy.mjs"
# The branch policy differs from the built-in fallback (review cap 3), so a
# resolution governed by the branch is visible in the output.
sed -e '/^\[rounds\.standard\]$/,/^$/ s/^review         = 3$/review         = 1/' \
    "$fixtures/policy.toml" >"$mbrepo/.devflow.toml"
cmp -s "$fixtures/policy.toml" "$mbrepo/.devflow.toml" &&
    err "the branch-policy edit changed nothing — update the sed alongside policy.toml"
(
    export GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_CONFIG_NOSYSTEM=1
    git config --global user.name conformance
    git config --global user.email conformance@example.invalid
    cd "$mbrepo"
    git init -q
    git add scripts agent-registry.json Taskfile.yml
    git commit -q -m "chore: merge base without the helper or a policy"
    git tag prehelper
    cp "$helper" scripts/lib/merge-base-policy.sh
    git add scripts/lib/merge-base-policy.sh
    git commit -q -m "chore: merge base without a policy"
    git tag base
    git add .devflow.toml
    git commit -q -m "feat: the branch adds the policy"
    git tag branch
    printf '%s\n' '#!/usr/bin/env bash' 'echo absent' >scripts/lib/merge-base-policy.sh
    git commit -q -am "fix: a branch that rewrites the helper to answer absent"
    git tag rogue
    git checkout -q -b no-policy-anywhere base
    printf '\n' >>agent-registry.json
    git commit -q -am "fix: a governing change on a repository with no policy anywhere"
    git tag nopolicy
    git checkout -q branch
) >/dev/null 2>&1 || err "could not build the merge-base scratch repository"

# run_caller BASE READER — the recipes' caller; prints the reader's stdout.
# The helper is a governing file: it runs the merge base's copy, else the
# operator pin in $pinned_mb_helper, else stops as indeterminate (status 2).
run_caller() {
    local base="$1" reader="$2" rel=scripts/lib/merge-base-policy.sh mb_helper mb_state
    rm -f "$scratch/mb-devflow.toml"
    if git cat-file -e "${base}:${rel}" 2>/dev/null; then
        mkdir -p "$scratch/mb-closure/scripts/lib"
        git show "${base}:${rel}" >"$scratch/mb-closure/$rel" || return 2
        mb_helper="$scratch/mb-closure/$rel"
    else
        mb_helper="${pinned_mb_helper:-}"
        [ -n "$mb_helper" ] || {
            echo "merge-base helper: the merge base predates it and no operator pin was supplied — indeterminate" >&2
            return 2
        }
    fi
    mb_state="$(bash "$mb_helper" "$base" "$reader" "$scratch/mb-devflow.toml" .devflow.toml)" || return 1
    case "$mb_state" in
    present) mb_policy=(--merge-base-policy "$scratch/mb-devflow.toml") ;;
    absent) mb_policy=(--merge-base-policy-absent) ;;
    none) mb_policy=() ;;
    *) return 1 ;;
    esac
    node "$reader" resolve --policy .devflow.toml ${mb_policy[@]+"${mb_policy[@]}"} \
        --merge-base-registry agent-registry.json --registry agent-registry.json \
        --taskfile-dir . --json
}

set +e
state="$(cd "$mbrepo" && bash "$helper" base "$mbrepo/scripts/devflow-policy.mjs" "$scratch/mb-absent.toml" .devflow.toml)"
st=$?
set -e
if [ "$st" -eq 0 ] && [ "$state" = "absent" ] && [ ! -e "$scratch/mb-absent.toml" ]; then
    echo "  ✓ a merge base without .devflow.toml answers absent and writes nothing"
else
    err "absent merge base: exit $st, answer '$state'"
fi

set +e
(cd "$mbrepo" && run_caller base "$mbrepo/scripts/devflow-policy.mjs") >"$scratch/caller-absent.json" 2>"$scratch/caller-absent.err"
st=$?
set -e
if [ "$st" -eq 0 ] && node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(r.source === "built-in-fallback" && r.rounds.review === 3 ? 0 : 1);
' "$scratch/caller-absent.json"; then
    echo "  ✓ a branch that adds the policy resolves under the built-in fallback, not its own policy"
else
    err "branch-adds-policy caller exited $st: $(head -2 "$scratch/caller-absent.err")"
fi

set +e
state="$(cd "$mbrepo" && bash "$helper" branch "$mbrepo/scripts/devflow-policy.mjs" "$scratch/mb-present.toml" .devflow.toml)"
st=$?
set -e
if [ "$st" -eq 0 ] && [ "$state" = "present" ] && cmp -s "$scratch/mb-present.toml" "$mbrepo/.devflow.toml"; then
    echo "  ✓ a merge base with .devflow.toml answers present and materializes its bytes"
else
    err "present merge base: exit $st, answer '$state'"
fi

set +e
(cd "$mbrepo" && bash "$helper" no-such-rev "$mbrepo/scripts/devflow-policy.mjs" "$scratch/mb-bad.toml" .devflow.toml) >"$scratch/bad.out" 2>/dev/null
bad=$?
(cd "$mbrepo" && bash "$helper" "" "$mbrepo/scripts/devflow-policy.mjs" "$scratch/mb-bad.toml" .devflow.toml) >"$scratch/empty.out" 2>/dev/null
empty=$?
set -e
if [ "$bad" -eq 2 ] && [ "$empty" -eq 2 ] && [ ! -s "$scratch/bad.out" ] && [ ! -s "$scratch/empty.out" ]; then
    echo "  ✓ an unresolvable or empty merge base is indeterminate, never absent"
else
    err "bad merge base: exit $bad / empty merge base: exit $empty (want 2 and 2, no answer)"
fi

# Criterion 4: an older reader that accepts any option would ignore the flag
# and let the branch policy govern. The caller must stop before running it.
printf '%s\n' 'process.stdout.write("OLD-READER-RAN\n");' >"$scratch/old-reader.mjs"
set +e
(cd "$mbrepo" && run_caller base "$scratch/old-reader.mjs") >"$scratch/caller-old.out" 2>"$scratch/caller-old.err"
st=$?
set -e
if [ "$st" -ne 0 ] && grep -Fq 'predates --merge-base-policy-absent' "$scratch/caller-old.err" &&
    ! grep -Fq 'OLD-READER-RAN' "$scratch/caller-old.out"; then
    echo "  ✓ the caller stops rather than hand the flag to a reader that predates it"
else
    err "the caller ran a reader that predates --merge-base-policy-absent (exit $st)"
fi

# The helper governs too (harmon-devkit#1345, disposition 1): a branch that
# rewrites it to answer "absent" must not swap the merge-base policy for the
# built-in fallback. The branch copy really does lie (the control below), so
# only running the merge base's copy keeps the merge-base policy (review 1).
set +e
state="$(cd "$mbrepo" && git checkout -q rogue && bash scripts/lib/merge-base-policy.sh branch x y)"
(cd "$mbrepo" && run_caller branch "$mbrepo/scripts/devflow-policy.mjs") >"$scratch/caller-rogue.json" 2>"$scratch/caller-rogue.err"
st=$?
set -e
if [ "$state" = "absent" ] && [ "$st" -eq 0 ] && node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(r.source !== "built-in-fallback" && r.rounds.review === 1 ? 0 : 1);
' "$scratch/caller-rogue.json"; then
    echo "  ✓ a branch that rewrites the helper to answer absent still resolves the merge-base policy"
else
    err "rogue helper: control answered '$state', caller exited $st: $(head -2 "$scratch/caller-rogue.err")"
fi

# First adoption: a merge base that predates the helper stops as
# indeterminate without an operator pin, never running the branch's copy, and
# runs the pin when one is supplied.
set +e
(cd "$mbrepo" && run_caller prehelper "$mbrepo/scripts/devflow-policy.mjs") >"$scratch/caller-nopin.out" 2>"$scratch/caller-nopin.err"
st=$?
(cd "$mbrepo" && pinned_mb_helper="$helper" run_caller prehelper "$mbrepo/scripts/devflow-policy.mjs") >"$scratch/caller-pin.json" 2>"$scratch/caller-pin.err"
pst=$?
set -e
(cd "$mbrepo" && git checkout -q branch) || err "could not restore the scratch checkout"
if [ "$st" -eq 2 ] && [ ! -s "$scratch/caller-nopin.out" ] && grep -Fq 'indeterminate' "$scratch/caller-nopin.err"; then
    echo "  ✓ a merge base that predates the helper stops as indeterminate without an operator pin"
else
    err "first adoption without a pin exited $st (want 2, no output)"
fi
if [ "$pst" -eq 0 ] && node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(r.source === "built-in-fallback" ? 0 : 1);
' "$scratch/caller-pin.json"; then
    echo "  ✓ a merge base that predates the helper runs the operator-pinned helper"
else
    err "first adoption with a pin exited $pst: $(head -2 "$scratch/caller-pin.err")"
fi

# Neither side has a policy (challenge round 1): step 0 fired on another
# governing file, so the helper answers "none" and each recipe passes NEITHER
# merge-base flag; the reader refuses --merge-base-policy-absent without an
# existing --policy file. run_recipe mirrors each recipe's own invocation:
# step 0 resolves the closure's reader with --taskfile-dir <closure>;
# /integrate re-execs through --closure with --taskfile-dir . It records the
# merge-base arguments it passed in $scratch/recipe-args.
run_recipe() {
    local mode="$1" base="$2" dir="$scratch/recipe-$1" mb_state
    rm -rf "$dir"
    mkdir -p "$dir/scripts/lib"
    git show "${base}:scripts/devflow-policy.mjs" >"$dir/scripts/devflow-policy.mjs" &&
        git show "${base}:scripts/lib/toml-lite.mjs" >"$dir/scripts/lib/toml-lite.mjs" &&
        git show "${base}:scripts/lib/merge-base-policy.sh" >"$dir/scripts/lib/merge-base-policy.sh" &&
        git show "${base}:agent-registry.json" >"$dir/agent-registry.json" &&
        git show "${base}:Taskfile.yml" >"$dir/Taskfile.yml" || return 2
    mb_state="$(bash "$dir/scripts/lib/merge-base-policy.sh" "$base" "$dir/scripts/devflow-policy.mjs" \
        "$dir/devflow.toml" .devflow.toml)" || return 1
    case "$mb_state" in
    present) mb_policy=(--merge-base-policy "$dir/devflow.toml") ;;
    absent) mb_policy=(--merge-base-policy-absent) ;;
    none) mb_policy=() ;;
    *) return 1 ;;
    esac
    printf '%s|%s\n' "$mb_state" "${mb_policy[*]-}" >"$scratch/recipe-args"
    case "$mode" in
    step0)
        node "$dir/scripts/devflow-policy.mjs" resolve --policy .devflow.toml ${mb_policy[@]+"${mb_policy[@]}"} \
            --merge-base-registry "$dir/agent-registry.json" --registry agent-registry.json \
            --taskfile-dir "$dir" --json
        ;;
    integrate)
        node "$dir/scripts/devflow-policy.mjs" resolve --closure "$dir" \
            --policy .devflow.toml ${mb_policy[@]+"${mb_policy[@]}"} \
            --merge-base-registry "$dir/agent-registry.json" \
            --registry agent-registry.json --taskfile-dir . --json
        ;;
    esac
}

for mode in step0 integrate; do
    for case_ in "nopolicy base none built-in-fallback" "branch base absent built-in-fallback"; do
        read -r head mbase answer source_ <<<"$case_"
        set +e
        (cd "$mbrepo" && git checkout -q "$head" && run_recipe "$mode" "$mbase") \
            >"$scratch/recipe.json" 2>"$scratch/recipe.err"
        st=$?
        set -e
        want_flag=""
        [ "$answer" = absent ] && want_flag="--merge-base-policy-absent"
        if [ "$st" -eq 0 ] && [ "$(cat "$scratch/recipe-args")" = "$answer|$want_flag" ] && node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(r.source === process.argv[2] ? 0 : 1);
' "$scratch/recipe.json" "$source_"; then
            echo "  ✓ $mode recipe, head $head: answers $answer, passes '${want_flag:-no flag}', resolves $source_"
        else
            err "$mode recipe, head $head: exit $st, args '$(cat "$scratch/recipe-args" 2>/dev/null)': $(head -2 "$scratch/recipe.err")"
        fi
    done
done
(cd "$mbrepo" && git checkout -q branch) || err "could not restore the scratch checkout"

# The integration chain — integrate's merge-base recipe, then its integration
# exit — resolves ONE governing policy in every merge-base state
# (harmon-devkit#1345, challenge rounds 2 and 3). run_integrate_chain mirrors
# the recipe and runs its trusted_copy verbatim, lifted from integrate/SKILL.md,
# so the selection rule under test is the one the skill ships.
echo "==> the integration chain resolves one governing policy"
int_recipe="$repo_root/ai/skills/universal/integrate/SKILL.md"
trusted_copy_src="$(sed -n '/^trusted_copy() {$/,/^}$/p' "$int_recipe")"
[ -n "$trusted_copy_src" ] || err "integrate/SKILL.md defines no trusted_copy"
eval "$trusted_copy_src"

exrepo="$scratch/exrepo"
exfix="$repo_root/ai/schemas/fixtures/exit/integration-cap-reached-with-p1-capped"
assets_rel=ai/skills/universal/dev-flow-support/assets
mkdir -p "$exrepo/$assets_rel"
cp -R "$support/." "$exrepo/$assets_rel/"
# The fixture policy caps integration at 2, which its two gating cycles reach
# (capped); the built-in fallback caps it at 4 (continue). A branch copy at
# cap 5 makes a branch-governed resolution visible too.
sed -e 's/^integration = 2$/integration = 5/' "$exfix/policy.toml" >"$scratch/branch-cap5.toml"
cmp -s "$exfix/policy.toml" "$scratch/branch-cap5.toml" &&
    err "the cap-5 edit changed nothing — update the sed alongside the fixture policy"
(
    export GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_CONFIG_NOSYSTEM=1
    cd "$exrepo"
    git init -q
    git add -A
    git commit -q -m "chore: merge base without a policy"
    git tag mbnone
    git checkout -q -b old-engine
    printf '%s\n' '// --run --stage --policy --json --merge-base-policy' \
        'process.stdout.write("OLD-ENGINE-RAN\n");' >"$assets_rel/dev-flow-exit.mjs"
    git commit -q -am "chore: merge base whose engine predates the absent flag"
    git tag oldengine
    git checkout -q mbnone
    cp "$exfix/policy.toml" .devflow.toml
    git add .devflow.toml
    git commit -q -m "chore: merge base with a policy"
    git tag mbpresent
    printf '%s\n' 'process.stdout.write(JSON.stringify({ outcome: "converged" }) + "\n");' \
        'process.exitCode = 20;' >"$assets_rel/dev-flow-exit.mjs"
    git commit -q -am "fix: a branch whose engine always converges"
    git tag rogue
) >/dev/null 2>&1 || err "could not build the integration-chain scratch repository"

# at REV [POLICY] — check out REV and make POLICY the branch's .devflow.toml
# ("-" removes it), as an uncommitted edit.
at() {
    git checkout -q -f "$1" && git clean -qfd || return 1
    case "${2:-}" in
    "") ;;
    -) rm -f .devflow.toml ;;
    *) cp "$2" .devflow.toml ;;
    esac
}

# run_integrate_chain BASE — the reader's JSON lands in chain-reader.json, the
# engine's in chain-exit.json; returns the engine's status, or 90 on a stop.
run_integrate_chain() {
    local base="$1" reader_dir="$assets_rel" mb_dir="$scratch/chain-mb" mb_helper mb_state mb_engine
    local -a exit_args
    rm -rf "$mb_dir" "$scratch/chain-reader.json" "$scratch/chain-exit.json"
    mkdir -p "$mb_dir"
    git archive --format=tar "$base" -- "$reader_dir" | tar -x -C "$mb_dir" || return 90
    mb_helper="$(trusted_copy "$mb_dir/${reader_dir}/lib/merge-base-policy.sh" "${pinned_mb_helper:-}")"
    [ -n "$mb_helper" ] || return 90
    mb_state="$(bash "$mb_helper" "$base" "$mb_dir/${reader_dir}/devflow-policy.mjs" \
        "$mb_dir/devflow.toml" .devflow.toml)" || return 90
    case "$mb_state" in
    present) mb_policy=(--merge-base-policy "$mb_dir/devflow.toml") ;;
    absent) mb_policy=(--merge-base-policy-absent) ;;
    none) mb_policy=() ;;
    *) return 90 ;;
    esac
    # No registry here: the reader then exits 3 (unchecked references) but
    # still prints the resolution, and only its governing caps are compared.
    node "$mb_dir/${reader_dir}/devflow-policy.mjs" resolve --closure "$mb_dir" \
        --policy .devflow.toml ${mb_policy[@]+"${mb_policy[@]}"} --json >"$scratch/chain-reader.json" 2>/dev/null
    exit_args=(--run "$exfix/run" --stage integration --policy .devflow.toml
        ${mb_policy[@]+"${mb_policy[@]}"} --json)
    mb_engine="$(trusted_copy "$mb_dir/${reader_dir}/dev-flow-exit.mjs" "${pinned_mb_engine:-}" "${exit_args[@]}")"
    [ -n "$mb_engine" ] || return 90
    node "$mb_engine" "${exit_args[@]}" >"$scratch/chain-exit.json"
}

# json_field FILE EXPR — EXPR evaluated against the parsed FILE as `r`.
json_field() {
    node -e '
const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(String(eval(process.argv[2])));
' "$1" "$2" 2>/dev/null || true
}

# The three-state table: state, checkout, branch policy, the cap the reader
# must resolve, and the verdict the engine must reach under that same cap.
while read -r state rev policy cap verdict; do
    set +e
    (cd "$exrepo" && at "$rev" "$policy" && run_integrate_chain "$rev") 2>"$scratch/chain.err"
    st=$?
    set -e
    got_cap="$(json_field "$scratch/chain-reader.json" r.rounds.integration)"
    got_verdict="$(json_field "$scratch/chain-exit.json" r.outcome)"
    if [ "$got_cap" = "$cap" ] && [ "$got_verdict" = "$verdict" ]; then
        echo "  ✓ $state: the reader resolves integration cap $cap and the engine decides under it ($verdict)"
    else
        err "$state: reader cap '$got_cap' (want $cap), engine '$got_verdict' exit $st (want $verdict): $(head -2 "$scratch/chain.err")"
    fi
done <<EOF
present mbpresent $scratch/branch-cap5.toml 2 capped
absent mbnone $exfix/policy.toml 4 continue
none mbnone - 4 continue
EOF

# A branch engine that always converges must not change the verdict.
set +e
(cd "$exrepo" && at rogue && node "$assets_rel/dev-flow-exit.mjs") >"$scratch/exit-ctl.json" 2>/dev/null
ctl=$?
(cd "$exrepo" && at rogue && run_integrate_chain mbpresent) 2>"$scratch/chain.err"
st=$?
set -e
if [ "$ctl" -eq 20 ] && [ "$(json_field "$scratch/exit-ctl.json" r.outcome)" = converged ] &&
    [ "$st" -eq 22 ] && [ "$(json_field "$scratch/chain-exit.json" r.outcome)" = capped ]; then
    echo "  ✓ a branch engine that always converges does not change the verdict (capped)"
else
    err "rogue engine: control exit $ctl, chain exit $st: $(head -2 "$scratch/chain.err")"
fi

# A merge-base engine too old for a flag the recipe passes: the pin runs when
# supplied, otherwise the recipe stops and the old engine never runs.
set +e
(cd "$exrepo" && at oldengine "$exfix/policy.toml" && run_integrate_chain oldengine) >"$scratch/old-nopin.out" 2>&1
st=$?
(cd "$exrepo" && at oldengine "$exfix/policy.toml" &&
    pinned_mb_engine="$support/dev-flow-exit.mjs" run_integrate_chain oldengine) >"$scratch/old-pin.out" 2>&1
pst=$?
set -e
if [ "$st" -eq 90 ] && ! grep -Fq OLD-ENGINE-RAN "$scratch/old-nopin.out" "$scratch/chain-exit.json" 2>/dev/null; then
    echo "  ✓ a too-old merge-base engine with no pin stops before it runs"
else
    err "too-old engine without a pin: exit $st (want 90, engine not run)"
fi
if [ "$pst" -eq 0 ] && [ "$(json_field "$scratch/chain-exit.json" r.outcome)" = continue ]; then
    echo "  ✓ a too-old merge-base engine with a pin runs the pin"
else
    err "too-old engine with a pin: exit $pst: $(head -2 "$scratch/old-pin.out")"
fi
(cd "$exrepo" && at mbpresent) || err "could not restore the chain scratch checkout"

if grep -Fq 'node "$mb_engine"' "$int_recipe" && grep -Fq '${pinned_mb_engine:-}' "$int_recipe" &&
    grep -Fq 'git archive --format=tar "$base" -- "$reader_dir"' "$int_recipe" &&
    grep -Fq 'trusted_copy "$mb_dir/${reader_dir}/dev-flow-exit.mjs"' "$int_recipe" &&
    grep -Fq 'lib/merge-base-policy.sh`, and the exit engine `dev-flow-exit.mjs`' "$int_recipe"; then
    echo "  ✓ integrate/SKILL.md runs the merge-base engine and routes engine edits to it"
else
    err "integrate/SKILL.md does not run the merge-base dev-flow-exit.mjs on the merge-base path"
fi

# Both recipes call the helper and pass its answer, never a bare
# `git show "${base}:.devflow.toml"` or an unconditional --merge-base-policy.
for recipe in "$repo_root/ai/skills/universal/dev-flow-support/SKILL.md" \
    "$repo_root/ai/skills/universal/integrate/SKILL.md"; do
    if grep -Fq 'lib/merge-base-policy.sh' "$recipe" && grep -Fq '${mb_policy[@]+"${mb_policy[@]}"}' "$recipe" &&
        grep -Fq 'none) mb_policy=()' "$recipe" && grep -Fq 'devflow.toml" .devflow.toml)' "$recipe" &&
        grep -Fq 'bash "$mb_helper"' "$recipe" && grep -Fq '${pinned_mb_helper:-}' "$recipe" &&
        ! grep -Fq '$support_dir/lib/merge-base-policy.sh' "$recipe" &&
        ! grep -Fq 'git show "${base}:.devflow.toml"' "$recipe"; then
        echo "  ✓ ${recipe#"$repo_root"/} carries the absent-base state"
    else
        err "${recipe#"$repo_root"/} does not decide its merge-base argument through lib/merge-base-policy.sh"
    fi
done

echo "==> conformance corpus against the vendored reader"
make_repo "$scratch/repo" "$support/devflow-policy.mjs"
if (cd "$scratch/repo" && python3 "$runner" --repo "$scratch/repo" --fixture "$corpus" --config "$scratch/repo/.devflow.toml"); then
    echo "  ✓ corpus passes"
else
    err "the vendored reader fails harmon-init's conformance corpus (output above)"
fi

echo "==> mutation control: a reader that ignores an honored pin must fail the corpus"
mutant="$scratch/mutant-devflow-policy.mjs"
# The one statement that applies an honored pin to the implementer. Any
# leading indentation is accepted and kept (the replacement reuses the
# captured whitespace), so a reformat of the reader does not silently
# disarm the control; an absent anchor, or a sed that changed nothing,
# still fails loudly.
anchor_re='^[[:space:]]*tier = pin\.tier;$'
if ! grep -Eq "$anchor_re" "$support/devflow-policy.mjs"; then
    err "mutation anchor 'tier = pin.tier;' not found — update the control alongside the reader"
elif ! sed -E 's/^([[:space:]]*)tier = pin\.tier;$/\1tier = profileTier;/' "$support/devflow-policy.mjs" >"$mutant" ||
    cmp -s "$support/devflow-policy.mjs" "$mutant"; then
    err "the mutation did not change the reader — the anchor matched but the substitution did not apply"
else
    make_repo "$scratch/mutant" "$mutant"
    if (cd "$scratch/mutant" && python3 "$runner" --repo "$scratch/mutant" --fixture "$corpus" --config "$scratch/mutant/.devflow.toml") >"$scratch/mutant.log" 2>&1; then
        err "the corpus PASSED a reader that ignores pins — the runner is not exercising the tier rungs"
    elif grep -q 'pin' "$scratch/mutant.log"; then
        echo "  ✓ mutant rejected ($(grep -c '^FAIL:' "$scratch/mutant.log") failing case(s))"
    else
        err "the mutant failed, but not on a pin case — inspect: $(head -3 "$scratch/mutant.log")"
    fi
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "  ✓ devflow conformance: vendored reader agrees with harmon-init ${SOURCE_REV:0:8}"
