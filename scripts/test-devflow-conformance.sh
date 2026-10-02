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
# The vendored inputs, all from harmon-init SOURCE_REV below:
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
# SOURCE_REV and the blob ids together. To confirm a harmon-init RELEASE
# still carries these bytes (the human follow-up on harmon-init#1464):
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

SOURCE_REV="81bbe78784c0b146e754e80030274ff95e10cf51"
CORPUS_BLOB="76ab10e3436b91f501b58e4c76a4e0776782feb8"
RUNNER_BLOB="9b8e67ed984cc7517ac1ffa16f97b2555c8e531a"
POLICY_BLOB="7e36129a43e0ae73c8a8c878e6055fdab8a1e6ab"
REGISTRY_BLOB="27844622efb4a7f8508729e6b413170b67bd7b3f"

repo_root="$(git rev-parse --show-toplevel)"
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
    local file="$1" want="$2" got
    if [ ! -f "$file" ]; then
        err "${file#"$repo_root"/} is missing"
        return 0
    fi
    got="$(git hash-object -- "$file")"
    if [ "$got" = "$want" ]; then
        echo "  ✓ ${file#"$repo_root"/}"
    else
        err "${file#"$repo_root"/} is blob $got, expected $want (harmon-init ${SOURCE_REV:0:8}) — re-vendor it, never hand-edit it"
    fi
    return 0
}
check_blob "$corpus" "$CORPUS_BLOB"
check_blob "$runner" "$RUNNER_BLOB"
check_blob "$fixtures/policy.toml" "$POLICY_BLOB"
check_blob "$fixtures/agent-registry.json" "$REGISTRY_BLOB"
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

echo "==> conformance corpus against the vendored reader"
make_repo "$scratch/repo" "$support/devflow-policy.mjs"
if (cd "$scratch/repo" && python3 "$runner" --repo "$scratch/repo" --fixture "$corpus" --config "$scratch/repo/.devflow.toml"); then
    echo "  ✓ corpus passes"
else
    err "the vendored reader fails harmon-init's conformance corpus (output above)"
fi

echo "==> mutation control: a reader that ignores an honored pin must fail the corpus"
mutant="$scratch/mutant-devflow-policy.mjs"
# The one statement that applies an honored pin to the implementer.
if ! grep -q '^      tier = pin.tier;$' "$support/devflow-policy.mjs"; then
    err "mutation anchor 'tier = pin.tier;' not found — update the control alongside the reader"
else
    sed 's/^      tier = pin\.tier;$/      tier = profileTier;/' "$support/devflow-policy.mjs" >"$mutant"
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
