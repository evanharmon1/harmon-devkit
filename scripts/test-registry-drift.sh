#!/usr/bin/env bash
# test-registry-drift.sh — the OFFLINE drift gate that binds label provisioning,
# provider wrappers, and Foreman adapter selectors to the machine-readable agent
# registry (agent-registry.json). Runs in `task verify` / `task ci` (ADR 0005
# D11: "later drift checks bind provisioning, wrappers, and the pinned upstream
# adapter roster to the same contract").
#
# The registry's SCHEMA and semantic invariants are the job of test-agent-registry.sh;
# this check adds the bindings between the registry and the things that consume it:
#
#   1. schema        — the registry still validates (fail fast before comparing).
#   2. label output  — the rendered suggest:/claim:/foreman: labels are exactly
#                      the family-level + provisionable set the registry implies
#                      (no agent:*, no seeded model-level, no non-production adapter).
#   3. provisioning  — setup-github-labels.sh renders those labels from the
#                      registry instead of hand-listing a forkable copy.
#   4. wrappers      — every claude-<family> provider wrapper maps to a
#                      provider-rewired harness registered in agent-registry.json.
#   5. adapters      — the provisionable Foreman adapters are internally coherent;
#                      the LIVE comparison against the pinned Foreman release is
#                      `task foreman:audit-adapters` (network — out of this gate).
#
# Dimensions 3 and 4 target files that only some render profiles ship
# (setup-github-labels.sh, claude-providers.sh); each is skipped, loudly, when
# its file is absent so the check passes across the whole render matrix.
#
# Every failure names the offending registry row / file and the remediation.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

registry="${1:-agent-registry.json}"
schema="${2:-agent-registry.schema.json}"
validator="scripts/validate-agent-registry.mjs"
renderer="scripts/agent-registry-labels.mjs"
labels_script="scripts/setup-github-labels.sh"
# The provider wrappers live under whichever devcontainer path the profile
# rendered; there is at most one.
wrappers_glob=".devcontainer/config/claude-providers.sh"

fails=0
fail() {
    echo "DRIFT: $*" >&2
    fails=$((fails + 1))
}

for required in "$registry" "$schema" "$validator" "$renderer"; do
    [ -f "$required" ] || {
        echo "TEST FAIL: missing required registry asset: $required" >&2
        exit 1
    }
done
for tool in node jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "TEST FAIL: $tool is required to check registry drift" >&2
        exit 1
    }
done

# ── 1. schema ──────────────────────────────────────────────────────────────
node "$validator" "$registry" "$schema" ||
    fail "registry fails its own schema — fix agent-registry.json before the bindings can be trusted"

# ── 2. label output ────────────────────────────────────────────────────────
# Render every label the registry implies and check the invariants the
# provisioning contract promises. jq reads the registry directly so the
# expectations are derived from the source of truth, not restated.
rendered="$(node "$renderer" all "$registry")"
names="$(printf '%s\n' "$rendered" | sed -n 's/|.*//p')"

# 2a. No retired agent:* labels may appear anywhere in the rendered set.
if printf '%s\n' "$names" | grep -q '^agent:'; then
    fail "rendered labels still contain a retired agent:* label — the agent vocabulary is now suggest:/claim: (ADR 0005 D6)"
fi

# 2b. Only FAMILY-level suggest:/claim: are seeded (exactly one colon in the
# name); a two-colon name would be a seeded model-level label.
if printf '%s\n' "$names" | grep -Eq '^(suggest|claim):[a-z0-9-]+:'; then
    fail "a model-level suggest:/claim: label is being seeded — model-level labels are created on demand, only family-level are provisioned (AC2)"
fi

# 2c. The suggest:/claim: names are EXACTLY one per registered family slug.
# Compare the derived name sets, not just counts: a renderer that emitted
# `suggest:claude` nine times would satisfy a count check (and collapse under a
# later sort -u) while provisioning only one of the nine expected families.
for ns in suggest claim; do
    want_ns="$(jq -r --arg p "$ns" '.families[].slug | $p + ":" + .' "$registry" | sort -u)"
    got_ns="$(printf '%s\n' "$names" | grep "^${ns}:" | sort -u || true)"
    [ "$want_ns" = "$got_ns" ] ||
        fail "rendered ${ns}:* labels [$(echo "$got_ns" | tr '\n' ' ')] != one-per-family expected [$(echo "$want_ns" | tr '\n' ' ')] — regenerate from agent-registry.json"
done

# 2d. foreman:<adapter> selectors are provisioned for EXACTLY the adapters the
# registry marks provision_label — no more (phantom selector), no fewer.
want_foreman="$(jq -r '.foreman_adapters[] | select(.provision_label == true) | "foreman:" + .slug' "$registry" | sort)"
got_foreman="$(printf '%s\n' "$names" | grep '^foreman:' | sort || true)"
if [ "$want_foreman" != "$got_foreman" ]; then
    fail "provisioned foreman:<adapter> selectors [$(echo "$got_foreman" | tr '\n' ' ')] != registry provision_label adapters [$(echo "$want_foreman" | tr '\n' ' ')] — a selector without a production adapter can strand armed work (ADR 0005 D11)"
fi

# ── 3. provisioning script ─────────────────────────────────────────────────
if [ -f "$labels_script" ]; then
    # It must delegate to a renderer, not carry a forkable hand-list. The
    # delegation is via the label-registry renderer, which spawns
    # agent-registry-labels.mjs for the agent families (source: agent-registry
    # in label-registry.json) — so the literal call this script once made
    # moved one level down, and the behavioral run below is what proves the
    # agent labels still come out.
    grep -Eq 'label-registry-render\.mjs|agent-registry-labels\.mjs' "$labels_script" ||
        fail "$labels_script does not render its labels from a registry (no label-registry-render.mjs or agent-registry-labels.mjs call) — hand-listed labels fork from the registries"
    # No hardcoded agent:* / suggest:* / claim:* / foreman:<family> selector
    # lines (the leading `word:` of a `name|color|desc` label line).
    if grep -Eq '^agent:[a-z0-9-]+\|' "$labels_script"; then
        fail "$labels_script still hard-lists a retired agent:* label line — remove it; the agent vocabulary is registry-rendered suggest:/claim: (ADR 0005 D6)"
    fi
    if grep -Eq '^(suggest|claim):[a-z0-9-]+\|' "$labels_script"; then
        fail "$labels_script hard-lists a suggest:/claim: label line — these must come from agent-registry-labels.mjs so they cannot fork from the registry"
    fi
    # Behavioral binding: actually RUN the provisioning script with `gh` stubbed
    # to just echo the label name, and confirm every registry-rendered label is
    # emitted. A filename grep alone would pass if a future edit called the wrong
    # renderer mode (suggest-claim vs foreman-adapters) or dropped a delegation;
    # running it observes what would really be provisioned. --foreman exercises
    # both renderer modes regardless of whether this profile arms Foreman.
    stub_dir="$(mktemp -d)"
    cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = label ] && { shift 2; printf '%s\n' "$1"; exit 0; }
exit 0
STUB
    chmod +x "$stub_dir/gh"
    emitted="$(PATH="$stub_dir:$PATH" bash "$labels_script" --repo drift/check --foreman 2>/dev/null | LC_ALL=C sort -u)"
    rm -rf "$stub_dir"
    # LC_ALL=C on the producers AND the consumer: `comm` re-derives the ordering
    # its inputs must already be in, so both sides have to agree on collation,
    # and label names carry `:`/`-`, which UTF-8 locales order differently than
    # byte value does.
    missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$names" | LC_ALL=C sort -u) <(printf '%s\n' "$emitted"))"
    if [ -n "$missing" ]; then
        fail "$labels_script did not provision registry label(s) [$(echo "$missing" | tr '\n' ' ')] when run — it must render every mode (suggest-claim AND foreman-adapters) from agent-registry-labels.mjs"
    fi
    # ...and the REVERSE direction: the script must not emit a registry-namespace
    # label the registry does not define. suggest:/claim: are wholly registry-owned;
    # in foreman:, only the <adapter> selectors are — the four protocol labels are
    # foreman's own workflow state and are legitimately static. Without this, a
    # re-added hardcoded phantom selector (e.g. `foreman:codex` with no adapter)
    # would sail through, which is the exact failure this gate exists to stop.
    # `extra` = emitted registry-namespace labels minus {protocol} minus {registry}.
    extra="$(printf '%s\n' "$emitted" | grep -E '^(suggest|claim|foreman):' |
        grep -vxF -e foreman:approved -e foreman:hold -e foreman:satisfied -e foreman:external |
        grep -vxF -f <(printf '%s\n' "$names") || true)"
    if [ -n "$extra" ]; then
        fail "$labels_script provisions registry-namespace label(s) [$(echo "$extra" | tr '\n' ' ')] the registry does not define — a hardcoded selector (e.g. a re-added phantom foreman:<adapter>) bypasses the registry (ADR 0005 D11)"
    fi
else
    echo "note: $labels_script not present in this profile — skipping the provisioning-script binding" >&2
fi

# ── 4. provider-wrapper inventory ──────────────────────────────────────────
# Every claude-<family>[-local] wrapper that ships MUST correspond to a
# provider-rewired harness claude-code-<family>[-local] in the registry (no
# orphan wrappers). The -local suffix is a sanctioned endpoint-variant marker
# (ADR 0005 D9 amendment) for a wrapper of the SAME family, not a distinct
# "<family>-local" family — claude-qwen-local() maps to family "qwen", not
# "qwen-local" — so it is stripped before the family lookup but kept in the
# harness slug. The reverse mapping is allowed: the registry may declare a
# provider-rewired harness ahead of its wrapper (e.g. claude-code-minimax
# before a claude-minimax launcher exists).
if [ -f "$wrappers_glob" ]; then
    wrappers="$(sed -n -E 's/^(claude-[a-z0-9-]+)\(\)[[:space:]]*\{.*/\1/p' "$wrappers_glob")"
    for fn in $wrappers; do
        stem="${fn#claude-}"
        family="${stem%-local}"
        harness="claude-code-${stem}"
        ok="$(jq -r --arg h "$harness" --arg f "$family" '
            [.harnesses[]
             | select(.slug == $h
                      and .provider_rewired == true
                      and .family_constraint.kind == "fixed"
                      and .family_constraint.family == $f)] | length' "$registry")"
        fam_ok="$(jq -r --arg f "$family" '[.families[] | select(.slug == $f)] | length' "$registry")"
        if [ "$ok" != 1 ] || [ "$fam_ok" -lt 1 ]; then
            fail "provider wrapper '$fn' in $wrappers_glob has no matching registry row — add a provider-rewired harness '$harness' (family_constraint fixed→$family) and a family '$family' to agent-registry.json, or remove the wrapper"
        fi
    done
else
    echo "note: no provider-wrapper file ($wrappers_glob) in this profile — skipping the wrapper binding" >&2
fi

# ── 5. Foreman adapter internal coherence ──────────────────────────────────
# The live comparison against the pinned Foreman release is task
# audit:foreman-adapters (network). Here we assert the provisionable adapters
# are self-consistent so a bad row is caught offline too.
bad_provision="$(jq -r '
    .foreman_adapters[]
    | select(.provision_label == true
             and (.classification != "production"
                  or .production_dispatchable != true
                  or .harness == null))
    | .slug' "$registry")"
if [ -n "$bad_provision" ]; then
    fail "foreman adapter(s) [$(echo "$bad_provision" | tr '\n' ' ')] set provision_label:true but are not a production, dispatchable, harness-mapped adapter — a public selector must map to real production machinery (ADR 0005 D11)"
fi

# The arming label is foreman:<slug>, but Foreman resolves it to the backend
# FILE, so a row whose slug differs from its source_file stem (e.g. slug "typo"
# with source_file "codex.sh") provisions a selector that arms nothing. Slugs are
# already unique (schema), so requiring slug == stem also makes source_files
# unique — closing the duplicate-source_file case the live audit's sort -u hides.
stem_mismatch="$(jq -r '
    .foreman_adapters[]
    | select((.source_file | rtrimstr(".sh")) != .slug)
    | "\(.slug)(->\(.source_file))"' "$registry")"
if [ -n "$stem_mismatch" ]; then
    fail "foreman adapter slug != source_file stem [$(echo "$stem_mismatch" | tr '\n' ' ')] — foreman:<slug> would not resolve to its backend file; rename the slug or the source_file so they match"
fi

if [ "$fails" -ne 0 ]; then
    echo "test-registry-drift: $fails drift finding(s) above." >&2
    echo "Live Foreman adapter roster check (network, non-gating): task foreman:audit-adapters" >&2
    exit 1
fi

echo "test-registry-drift: registry, labels, provisioning, wrappers, and adapters agree."
echo "  (live Foreman roster check is task foreman:audit-adapters — network, not part of this gate)"
