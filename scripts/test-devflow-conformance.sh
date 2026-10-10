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

SOURCE_REV="3fd05eb6a2740c818e2c5a56bd46491505e889b6"
REGISTRY_SOURCE_REV="81bbe78784c0b146e754e80030274ff95e10cf51"
CORPUS_BLOB="13b4a79bfc2684416d83575d28f028bae7820f8c"
RUNNER_BLOB="9dee6a66350ed50fbe8689500115f64a5d06827a"
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
