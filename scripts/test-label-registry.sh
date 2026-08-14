#!/usr/bin/env bash
# test-label-registry.sh — the offline gate for the machine-readable label
# taxonomy (label-registry.json): its schema and cross-record invariants, the
# renderer that turns it into `name|color|description` records, and the two
# consumers bound to that renderer.
#
# Runs in `task verify` / `task ci`. No network and no GitHub — `gh` is
# PATH-stubbed, so the provisioning binding is observed rather than trusted.
#
# Five groups:
#   1. validator      — every schema and semantic invariant rejects a manifest
#                       that violates it, and the diagnostic names the offender.
#                       A gate nobody has seen bite is a gate nobody can trust.
#   2. renderer       — the record-transport guards fail closed on the fields a
#                       structural schema cannot forbid (a `|` or a newline in a
#                       description would inject a whole extra label).
#   3. cross-file     — the `rigor` family and `.devflow.toml`'s `[rigor.*]`
#                       tables name the same tiers, checked in both directions:
#                       a label with no table resolves to nothing, and a table
#                       with no label cannot be selected.
#   4. render         — GOLDEN-SET byte identity against the label set this repo
#                       provisioned before the manifest existed, plus the
#                       hand-seeded families it absorbs; tool-owned and
#                       github-default values never rendered; the
#                       agent-registry-composed families byte-identical to
#                       agent-registry-labels.mjs; `all` == provision + foreman.
#   5. provisioning   — setup-github-labels.sh provisions EXACTLY the rendered
#                       set, compared with `comm` in both directions: a missing
#                       label leaves a repo unseeded, and an extra one is a
#                       hand-list that has forked from the manifest.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

registry="${1:-label-registry.json}"
schema="${2:-label-registry.schema.json}"
validator="scripts/validate-label-registry.mjs"
renderer="scripts/label-registry-labels.mjs"
agent_renderer="scripts/agent-registry-labels.mjs"
labels_script="scripts/setup-github-labels.sh"
devflow=".devflow.toml"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Containment tests done in-shell rather than with `printf … | grep -q`. Under
# `set -o pipefail`, `grep -q` exits on its first match and can SIGPIPE the
# writer, so the pipeline reports 141 and a MATCH reads as a miss — rarely, and
# only on long input, which is the worst way for an assertion to be wrong.
# contains_line NEWLINE_LIST LINE — exact whole-line membership.
contains_line() {
    local haystack="
$1
" needle="
$2
"
    case "$haystack" in
    *"$needle"*) return 0 ;;
    esac
    return 1
}

# has_line_prefix NEWLINE_LIST PREFIX — any line starting with PREFIX.
has_line_prefix() {
    local haystack="
$1" needle="
$2"
    case "$haystack" in
    *"$needle"*) return 0 ;;
    esac
    return 1
}

# count_lines NEWLINE_LIST — 0 for the empty string, where `grep -c '^'` would
# say 1 (and exit non-zero on a genuinely empty stream, aborting under `set -e`).
count_lines() {
    [ -n "$1" ] || {
        echo 0
        return 0
    }
    printf '%s\n' "$1" | wc -l | tr -d ' '
}

for required in "$registry" "$schema" "$validator" "$renderer" "$agent_renderer" "$labels_script"; do
    [ -f "$required" ] || fail "missing required label-taxonomy asset: $required"
done
for tool in node jq; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required to test the label registry"
done

node "$validator" "$registry" "$schema"

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
mutated="${test_tmp}/label-registry.json"
# The schema travels WITH the manifest: both the validator and the renderer
# resolve it as a sibling of the manifest they are given, so a fixture needs its
# own copy or every renderer case would fail on a missing schema instead of on
# the mutation under test.
cp "$schema" "${test_tmp}/label-registry.schema.json"

# ── 1. validator ───────────────────────────────────────────────────────────
# Each case mutates the REAL manifest so the fixture cannot drift from it, then
# asserts the validator rejects it *for the stated reason* — an accidental pass
# for an unrelated error would leave the invariant untested.
build_mutation() {
    node --input-type=module - "$registry" "$mutated" "$1" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'

const [inputPath, outputPath, mutation] = process.argv.slice(2)
const registry = JSON.parse(await readFile(inputPath, 'utf8'))
const family = (id) => {
  const found = registry.families.find((entry) => entry.family === id)
  if (!found) throw new Error(`fixture drift: no family '${id}' in the manifest`)
  return found
}
const value = (id, name) => {
  const found = (family(id).values ?? []).find((entry) => entry.name === name)
  if (!found) throw new Error(`fixture drift: no value '${name}' in family '${id}'`)
  return found
}
const composed = () => {
  const found = registry.families.find((entry) => entry.source === 'agent-registry')
  if (!found) throw new Error('fixture drift: no agent-registry-composed family')
  return found
}

switch (mutation) {
  case 'duplicate-family':
    registry.families.push(structuredClone(registry.families[0]))
    break
  case 'duplicate-value':
    family('concerns').values.push(structuredClone(value('concerns', 'sec')))
    break
  case 'collide-rendered-name':
    // A second bare-name family re-declaring `sec`: distinct family id, same
    // rendered label, so two families would provision one label.
    registry.families.push({
      ...structuredClone(family('concerns')),
      family: 'concerns-extra'
    })
    break
  case 'shared-prefix':
    family('method').prefix = 'tier'
    break
  case 'overlong-description':
    value('concerns', 'sec').description = 'x'.repeat(101)
    break
  case 'lowercase-color':
    family('concerns').color = '5319e7'
    break
  case 'unknown-writer':
    family('concerns').writers = ['robot']
    break
  case 'unknown-family-property':
    family('concerns').escalates_to = 'nothing'
    break
  case 'values-on-composed-family':
    composed().values = [{ name: 'smuggled', description: 'not from the agent registry' }]
    break
  case 'composed-family-without-mode':
    delete composed().registry
    break
  case 'composed-mode-prefix-mismatch':
    family('foreman').registry.mode = 'suggest-claim'
    break
  case 'overlong-rendered-name':
    // 45 chars passes the 50-char cap on the value's own name; `method:` in
    // front of it does not.
    value('method', 'oneshot').name = 'x'.repeat(45)
    break
  case 'github-default-with-color':
    value('work-type', 'bug').color = '112233'
    break
  case 'github-default-with-description':
    value('work-type', 'bug').description = 'Something is not working'
    break
  case 'tool-owned-agent-writable':
    value('foreman', 'dispatched').writers = ['tool:foreman', 'agent']
    break
  case 'tool-writers-not-tool-owned':
    family('rigor').writers = ['tool:foreman']
    break
  case 'provisioned-without-description':
    delete value('concerns', 'sec').description
    break
  case 'provisioned-without-color':
    // The work-type family carries no family colour, so removing the value's
    // leaves nothing for `gh label create --color` to use.
    delete value('work-type', 'task').color
    break
  case 'second-work-type-axis':
    family('area').axis = 'work-type'
    break
  case 'work-type-not-exclusive':
    family('work-type').exclusive = false
    break
  case 'composed-family-without-color':
    delete family('claim').color
    break
  case 'shouty-prefix-impersonation':
    // GitHub reads this as `foreman:new-backend`, so folding matters.
    value('work-type', 'task').name = 'Foreman:new-backend'
    break
  case 'case-only-collision':
    // GitHub treats `Task` and `task` as one label, so this is a collision even
    // though the two spellings differ.
    family('concerns').values.push({ name: 'SEC', description: 'Shouty security concern' })
    break
  case 'case-only-collision-across-families':
    value('work-type', 'task').name = 'Blocked'
    break
  case 'bare-value-impersonating-prefix':
    // Renders `foreman:claude` from the work-type family — the same label the
    // foreman family composes from agent-registry.json.
    value('work-type', 'task').name = 'foreman:claude'
    break
  case 'inline-family-without-values':
    // The fail-open case: without validation the renderer would treat this as an
    // empty family and emit a SHORTER label set that both consumers accept.
    delete family('concerns').values
    break
  case 'collide-with-composed':
    // `foreman:claude` is composed from agent-registry.json; renaming a protocol
    // value onto it makes one label carry two records.
    value('foreman', 'approved').name = 'claude'
    break
  case 'space-in-provisioned-name':
    value('concerns', 'sec').name = 'sec urity'
    break
  case 'nul-in-description':
    // Bash strips NUL from a command substitution silently, so this is the one
    // transport hazard that MUTATES the record instead of splitting it.
    value('concerns', 'sec').description = `Security${String.fromCharCode(0)}concern`
    break
  case 'composed-onto-tool-owned-name':
    // `foreman:claude` is composed from agent-registry.json; renaming the
    // tool-owned `dispatched` onto it means provisioning would --force-rewrite a
    // label Foreman owns. The validator cannot see this: the composed half comes
    // from the other manifest, and the tool-owned half is never rendered.
    value('foreman', 'dispatched').name = 'claude'
    break
  case 'recolored-composed-family':
    // The manifest is the taxonomy's source of truth, but this family's records
    // come from agent-registry-labels.mjs with its own hard-coded color.
    family('claim').color = 'ABCDEF'
    break
  case 'pipe-in-description':
    value('concerns', 'sec').description = 'Security|FFFFFF|smuggled'
    break
  case 'newline-in-description':
    value('concerns', 'sec').description = 'Security\nrogue|FFFFFF|smuggled'
    break
  default:
    throw new Error(`unknown mutation: ${mutation}`)
}

await writeFile(outputPath, `${JSON.stringify(registry, null, 2)}\n`)
NODE
}

rejects() {
    local description="$1" mutation="$2" expected="$3" output

    build_mutation "$mutation" || fail "could not build mutation: $description"
    if output="$(node "$validator" "$mutated" "$schema" 2>&1)"; then
        fail "validator accepted mutation: $description"
    fi
    case "$output" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $output" ;;
    esac
    echo "PASS: rejects $description"
}

rejects "duplicate family ids" \
    'duplicate-family' 'duplicate family id'
rejects "the same value listed twice in one family" \
    'duplicate-value' "value 'sec' is listed twice"
rejects "two families rendering the same label name" \
    'collide-rendered-name' "label 'sec' is defined by both family"
rejects "two values in one family differing only in case" \
    'case-only-collision' 'GitHub label names are case-insensitive'
rejects "two families whose labels differ only in case" \
    'case-only-collision-across-families' 'the two differ only in case'
rejects "one prefix claimed by two families" \
    'shared-prefix' "share the prefix 'tier:'"
rejects "a description over GitHub's 100-character limit" \
    'overlong-description' 'must contain at most 100 character(s)'
rejects "a color that is not six uppercase hex digits" \
    'lowercase-color' 'does not match ^[0-9A-F]{6}$'
rejects "an unrecognized writer class" \
    'unknown-writer' 'writers[0]: does not match'
rejects "whitespace in a name this repo provisions" \
    'space-in-provisioned-name' "renders 'sec urity', which contains whitespace"
rejects "an unknown family property" \
    'unknown-family-property' 'unexpected property escalates_to'
rejects "an inline values list on an agent-registry-composed family" \
    'values-on-composed-family' 'must not be duplicated here'
rejects "an agent-registry-composed family with no registry.mode" \
    'composed-family-without-mode' 'no registry.mode'
rejects "a composition mode that cannot emit the family's prefix" \
    'composed-mode-prefix-mismatch' 'would compose zero labels'
rejects "a value whose name plus prefix exceeds GitHub's 50-character limit" \
    'overlong-rendered-name' "over GitHub's 50-char label-name limit"
rejects "a bare value rendering into another family's namespace" \
    'bare-value-impersonating-prefix' "opens with 'foreman:', the prefix of family foreman"
rejects "a differently-cased impersonation of another family's namespace" \
    'shouty-prefix-impersonation' "opens with 'foreman:', the prefix of family foreman"
rejects "an agent-registry-composed family with no color to compare against" \
    'composed-family-without-color' 'declares no color'
rejects "a github-default value restating GitHub's color" \
    'github-default-with-color' 'is github-default and sets a color'
rejects "a github-default value restating GitHub's description" \
    'github-default-with-description' 'is github-default and sets a description'
rejects "an agent-writable tool-owned value" \
    'tool-owned-agent-writable' 'is tool-owned and agent-writable'
rejects "tool-only writers on a family this repo provisions" \
    'tool-writers-not-tool-owned' 'lists only tool:<name> writers but is not tool-owned'
rejects "a provisioned value with no description" \
    'provisioned-without-description' 'is provisioned but has no description'
rejects "a provisioned value that resolves no color" \
    'provisioned-without-color' 'resolves no color'
rejects "a second family on the work-type axis" \
    'second-work-type-axis' 'expected exactly one family on the work-type axis, found 2'
rejects "a non-exclusive work-type family" \
    'work-type-not-exclusive' 'is not exclusive'

# ── 2. renderer: validation + transport guards ──────────────────────────────
# The renderer VALIDATES before it emits, because the operator who hand-edits the
# manifest runs `task setup:github-labels` and `task status`, not `task verify`.
# Rendering an unvalidated manifest fails open: a dropped `values` list yields a
# shorter set, provisioning reports success, and status reports the repo fully
# seeded from the same reduced output.
#
# Past that, a `|` or a newline inside a description is schema-VALID text that
# would split the record stream into extra labels; there the renderer's own field
# guards are the only thing between the manifest and `gh label create`.
renderer_rejects() {
    local description="$1" mutation="$2" expected="$3" output

    build_mutation "$mutation" || fail "could not build mutation: $description"
    if output="$(node "$renderer" all "$mutated" 2>&1)"; then
        fail "renderer accepted mutation: $description"
    fi
    case "$output" in
    *"$expected"*) ;;
    *) fail "$description failed for the wrong reason: $output" ;;
    esac
    echo "PASS: renderer rejects $description"
}

# The fail-open regression: a manifest the validator rejects must never render.
renderer_rejects "a manifest that fails validation" \
    'inline-family-without-values' 'refusing to render labels from it'
renderer_rejects "a pipe character in a description" \
    'pipe-in-description' "contains a newline, a '|', or a NUL"
renderer_rejects "a newline in a description" \
    'newline-in-description' "contains a newline, a '|', or a NUL"
# NUL is the one transport hazard that MUTATES rather than splits: bash strips it
# from a command substitution, so `gh` would get a shortened description.
renderer_rejects "a NUL in a description" \
    'nul-in-description' "contains a newline, a '|', or a NUL"
# The manifest owns the taxonomy, but a composed family's records carry
# agent-registry-labels.mjs's own color — recoloring one side alone must not
# leave provisioning and status on the old color while manifest readers see the new.
renderer_rejects "a composed family recolored in the manifest alone" \
    'recolored-composed-family' "disagree about this family's color"
# The skipped values are exactly the ones nothing else guards: they never become
# records, so only a reservation keeps a composed label off a tool-owned name.
renderer_rejects "a composed label landing on a tool-owned name" \
    'composed-onto-tool-owned-name' 'as one this repo never creates'
# Whitespace is caught twice — by the embedded validation pass and by the
# renderer's own field guard — and both say the same thing, so this asserts the
# outcome that matters: a spaced name never reaches `gh label create`.
renderer_rejects "whitespace in a name it would provision" \
    'space-in-provisioned-name' "which contains whitespace"
# The validator cannot see this one: the colliding name is composed from
# agent-registry.json, so the renderer is the only place both halves are visible.
renderer_rejects "an inline value colliding with a composed one" \
    'collide-with-composed' 'is rendered twice'

if node "$renderer" not-a-mode >/dev/null 2>&1; then
    fail "renderer accepted an unknown mode"
fi
echo "PASS: renderer rejects an unknown mode"

# ── 3. cross-file: rigor family <-> .devflow.toml ───────────────────────────
# Checked in both directions. A `rigor:*` label with no `[rigor.<value>]` table
# resolves to nothing (AGENTS.md ignores it rather than guessing), and a table
# with no label can never be selected on an issue.
if [ -f "$devflow" ]; then
    manifest_rigor="$(jq -r '.families[] | select(.family == "rigor") | .values[].name' \
        "$registry" | LC_ALL=C sort)"
    devflow_rigor="$(sed -n -E 's/^\[rigor\.([A-Za-z0-9_-]+)\][[:space:]]*$/\1/p' \
        "$devflow" | LC_ALL=C sort)"
    [ -n "$manifest_rigor" ] || fail "the manifest declares no rigor family values"
    [ -n "$devflow_rigor" ] || fail "$devflow declares no [rigor.*] tables"
    if [ "$manifest_rigor" != "$devflow_rigor" ]; then
        fail "rigor values [$(echo "$manifest_rigor" | tr '\n' ' ')] != $devflow tiers [$(echo "$devflow_rigor" | tr '\n' ' ')] — a label with no tier resolves to nothing and a tier with no label cannot be selected"
    fi
    default_rigor="$(sed -n -E 's/^default_rigor[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$devflow")"
    [ -n "$default_rigor" ] || fail "$devflow declares no default_rigor"
    contains_line "$manifest_rigor" "$default_rigor" ||
        fail "$devflow default_rigor '$default_rigor' is not a rigor family value — the fallback tier must be one an issue can also carry as a label"
    echo "PASS: rigor family and $devflow name the same tiers (default: $default_rigor)"
else
    echo "note: no $devflow in this profile — skipping the rigor cross-file check" >&2
fi

# ── 4. render invariants ────────────────────────────────────────────────────
rendered_all="$(node "$renderer" all)"
rendered_provision="$(node "$renderer" provision)"
rendered_foreman="$(node "$renderer" foreman)"
rendered_names="$(printf '%s\n' "$rendered_all" | sed -n 's/|.*//p')"

# 4a. `all` is exactly `provision` followed by `foreman` — three modes, one
# record per label, no chance of a mode-specific color or description.
if ! cmp -s <(printf '%s\n' "$rendered_all") \
    <(printf '%s\n%s\n' "$rendered_provision" "$rendered_foreman"); then
    fail "'$renderer all' is not 'provision' followed by 'foreman' — the modes disagree about some label's record"
fi
echo "PASS: all == provision + foreman"

# 4b. The arming axis is opt-in: `provision` must not leak it, because a repo
# that does not run foreman would then be told it is missing those labels.
if has_line_prefix "$rendered_provision" 'foreman:'; then
    fail "'$renderer provision' emitted a foreman:* label — the arming axis is opt-in (--foreman)"
fi
if ! has_line_prefix "$rendered_foreman" 'foreman:'; then
    fail "'$renderer foreman' rendered no foreman:* label"
fi
echo "PASS: the arming axis renders only under the foreman mode"

# 4c. GOLDEN SET. The literal block below is the label set this repo provisioned
# BEFORE label-registry.json existed — the heredoc in setup-github-labels.sh at
# the commit before this change, plus foreman's four protocol labels — captured
# byte-for-byte. Provisioning must RECONCILE with the live repo, not fight it, so
# a manifest that re-colored or re-worded an existing label would silently rewrite
# labels already on hundreds of issues. Beneath it are the families that were
# hand-seeded live and that no script provisioned until now: adopting them is the
# only intended change to the rendered set.
golden_pre_manifest="$(
    cat <<'GOLDEN'
sec|5319E7|Security concern
a11y|5319E7|Accessibility concern
perf|5319E7|Performance concern
tech-debt|5319E7|Technical debt
i18n|5319E7|Internationalization
l10n|5319E7|Localization
customer-request|EC4899|Requested by a customer
ai-generated|EC4899|Created or authored by an AI agent
needs-triage|E36209|Awaiting triage
needs-requirements|E36209|Requirements not yet defined
blocked|E36209|Blocked by a non-issue dependency (reason in a comment)
waiting|E36209|Waiting on an external party
needs-decision|E36209|Needs a decision before it can proceed
needs-response|E36209|Awaiting a response
needs-communication|E36209|An update needs to be communicated out
layer:ui|1D76DB|Components, styling, interaction, tokens, a11y. No data change
layer:logic|1D76DB|Business rules, handlers, calculation
layer:data|1D76DB|Schema, indexes, validators, migrations
layer:integration|1D76DB|External boundary: webhooks, API clients, credentials
domain:auth|FBCA04|Authentication and authorization
domain:billing|FBCA04|Billing and payments
domain:platform|FBCA04|CI, build, test infra, and tooling in this repo
rigor:light|D4C5F9|Dev Loop caps: trivial, low-blast-radius change
rigor:standard|D4C5F9|Dev Loop caps: the default budget
rigor:deep|D4C5F9|Dev Loop caps: security, migrations, irreversible paths
foreman:approved|1D76DB|Arm with the repo default backend
foreman:hold|D93F0B|Exclude from foreman dispatch (always wins)
foreman:satisfied|0E8A16|Human override: treat this dependency as satisfied
foreman:external|BFDADC|External dependency: satisfied when closed as completed
GOLDEN
)"
golden_hand_seeded="$(
    cat <<'GOLDEN'
tier:local|7057FF|Model tier: self-hosted endpoint first; may escalate to economy
tier:economy|7057FF|Model tier: cheapest qualified hosted model first; escalation allowed
tier:standard|7057FF|Model tier: reliable general-purpose coding model first
tier:frontier|7057FF|Model tier: opus-class heavyweights; no warm-up on weaker models
tier:apex|7057FF|Model tier: mythos-class leading edge (fable, sol)
tier:adaptive|7057FF|Model tier: cheap preflight classifies, then chooses or escalates
method:oneshot|BF3989|Execution: single agent, no separate plan phase
method:plan|BF3989|Execution: agent plans then implements; no human plan gate
method:plan-approved|BF3989|Execution: plan requires human approval before implementation
method:orchestrate|BF3989|Execution: conductor session drives subagents, possibly across related issues
method:council|BF3989|Execution: N independent implementations; judged, best or synthesis wins
method:human-led|BF3989|Execution: human owns central decisions; AI does bounded pieces
area:build|0E8A16|Build system and packaging
area:ci|0E8A16|GitHub Actions workflows and CI plumbing
area:deps|0E8A16|Dependency management and pins
area:docs|0E8A16|Documentation content and structure
area:skills|0E8A16|Agent skills (ai/skills) and their packaging
task|6E7781|General work: maintenance, chores, cleanup
research|0E7C86|Produces a decision or written answer, not a code change
GOLDEN
)"
# The suggest:/claim:/foreman:<adapter> families are composed from
# agent-registry.json, whose roster changes on its own schedule, so they are
# unioned in from the live renderer rather than frozen here. Their byte identity
# is proved by 4e below instead.
golden_expected="$(
    printf '%s\n%s\n' "$golden_pre_manifest" "$golden_hand_seeded"
    node "$agent_renderer" all
)"
if ! cmp -s \
    <(printf '%s\n' "$golden_expected" | LC_ALL=C sort -u) \
    <(printf '%s\n' "$rendered_all" | LC_ALL=C sort -u); then
    echo "TEST FAIL: rendered label set is not the pre-manifest set plus the hand-seeded families." >&2
    echo "  '<' = expected but not rendered, '>' = rendered but not expected:" >&2
    diff <(printf '%s\n' "$golden_expected" | LC_ALL=C sort -u) \
        <(printf '%s\n' "$rendered_all" | LC_ALL=C sort -u) >&2 || true
    exit 1
fi
echo "PASS: rendered set is byte-identical to the pre-manifest set plus the hand-seeded families"

# 4d. Nothing the manifest marks tool-owned or github-default may be rendered:
# provisioning one would race its owning tool or fight GitHub's own defaults.
# The list is DERIVED from the manifest rather than restated, so a newly
# documented tool label is covered the moment it is added.
never_rendered="$(jq -r '
    .families[]
    | . as $family
    | .values[]?
    | select(($family.source == "tool-owned") or has("source"))
    | if $family.prefix == null then .name else $family.prefix + ":" + .name end' "$registry")"
[ -n "$never_rendered" ] ||
    fail "the manifest documents no tool-owned or github-default value — this check would prove nothing"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if contains_line "$rendered_names" "$name"; then
        fail "label '$name' is marked tool-owned or github-default in $registry but is rendered for provisioning — it must be documented, never provisioned, never deleted"
    fi
done <<<"$never_rendered"
echo "PASS: tool-owned and github-default values are never rendered ($(count_lines "$never_rendered") checked)"

# 4e. The agent-registry-composed families pass through byte-identically: every
# line agent-registry-labels.mjs renders under a composed family's prefix must
# appear verbatim in our output, and our output must add nothing under that
# prefix beyond the family's own inline values. Reformatting a composed record
# here would fork the two manifests' color and description templates.
while IFS='|' read -r fam prefix mode inline_count; do
    [ -n "$fam" ] || continue
    want="$(node "$agent_renderer" "$mode" | grep "^${prefix}:" | LC_ALL=C sort -u)"
    got="$(printf '%s\n' "$rendered_all" | grep "^${prefix}:" | LC_ALL=C sort -u)"
    [ -n "$want" ] || fail "family $fam composes with mode '$mode' but $agent_renderer rendered no ${prefix}: label"
    dropped="$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
    [ -z "$dropped" ] ||
        fail "family $fam dropped or rewrote composed label(s) [$(echo "$dropped" | tr '\n' ' ')] — composed records must pass through verbatim"
    want_count="$(count_lines "$want")"
    got_count="$(count_lines "$got")"
    if [ "$got_count" -ne "$((want_count + inline_count))" ]; then
        fail "family $fam renders $got_count ${prefix}: label(s) but the agent registry composes $want_count and the manifest lists $inline_count inline — an unaccounted label under a composed prefix bypasses both manifests"
    fi
    echo "PASS: family $fam composes ${want_count} label(s) from $agent_renderer verbatim (+${inline_count} inline)"
done < <(jq -r '
    .families[]
    | select(has("registry"))
    | [ .family,
        .prefix,
        .registry.mode,
        ([ .values[]? | select(has("source") | not) ] | length | tostring)
      ] | join("|")' "$registry")

# 4f. Colors of the families this manifest adopts, asserted against the values
# they carry LIVE on the repo today. The golden set above pins them too, but this
# names the family when someone edits a color in the manifest.
while IFS=':' read -r fam want; do
    [ -n "$fam" ] || continue
    got="$(jq -r --arg f "$fam" '.families[] | select(.family == $f) | .color // "<none>"' "$registry")"
    [ "$got" = "$want" ] ||
        fail "family $fam declares color $got, expected the live color $want — provisioning must reconcile with the labels already on issues, not re-color them"
done <<'COLORS'
concerns:5319E7
provenance:EC4899
workflow-state:E36209
layer:1D76DB
domain:FBCA04
rigor:D4C5F9
suggest:BFD4F2
claim:006B75
foreman:1D76DB
tier:7057FF
method:BF3989
area:0E8A16
COLORS
echo "PASS: family colors match the live label colors"

# 4g. Exactly one exclusive work-type family — the invariant "an issue carries
# exactly one work type" is unenforceable with two.
work_type_families="$(jq -r '[.families[] | select(.axis == "work-type" and .exclusive == true)] | length' "$registry")"
[ "$work_type_families" = 1 ] ||
    fail "expected exactly one exclusive work-type family, found $work_type_families"
echo "PASS: exactly one exclusive work-type family"

# ── 5. provisioning binding ─────────────────────────────────────────────────
# Run the real provisioning script with `gh` stubbed to log the label names it
# would create, then compare with the rendered set in BOTH directions. A grep for
# the renderer's filename would pass a script that called the wrong mode or
# dropped a delegation; running it observes what would really reach GitHub.
gh_log="${test_tmp}/gh-labels.log"
stub_dir="${test_tmp}/stub"
mkdir -p "$stub_dir"
cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = label ] && [ "$2" = create ]; then
    printf '%s\n' "$3" >>"$GH_STUB_LOG"
fi
exit 0
STUB
chmod +x "$stub_dir/gh"

provisioned_names() {
    : >"$gh_log"
    GH_STUB_LOG="$gh_log" PATH="$stub_dir:$PATH" \
        bash "$labels_script" --repo test/label-registry "$@" >/dev/null
    LC_ALL=C sort -u "$gh_log"
}

# LC_ALL=C on the producers AND the consumer: `comm` re-derives the ordering its
# inputs must already be in, and label names carry `:` and `-`, which UTF-8
# locales order differently than byte value does.
compare_provisioned() {
    local label="$1" want="$2" got="$3" missing extra

    missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
    [ -z "$missing" ] ||
        fail "$labels_script ($label) did not provision rendered label(s) [$(echo "$missing" | tr '\n' ' ')] — a repo seeded with it would be missing them"
    extra="$(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
    [ -z "$extra" ] ||
        fail "$labels_script ($label) provisioned label(s) [$(echo "$extra" | tr '\n' ' ')] the manifest does not render — a hand-listed label has forked from $registry"
}

compare_provisioned "default" \
    "$(printf '%s\n' "$rendered_provision" | sed -n 's/|.*//p' | LC_ALL=C sort -u)" \
    "$(provisioned_names)"
echo "PASS: $labels_script provisions exactly the rendered provision set"

compare_provisioned "--foreman" \
    "$(printf '%s\n' "$rendered_names" | LC_ALL=C sort -u)" \
    "$(provisioned_names --foreman)"
echo "PASS: $labels_script --foreman provisions exactly the rendered full set"

# ── 6. status.sh's expected-label inventory ─────────────────────────────────
# `task status` must not call an incompletely seeded repo green, so status.sh
# derives its expected set from THIS renderer. That check sits inside the network
# fan-out of `status setup`, behind an authenticated `gh` probe — so it is RUN
# here against a fixture root with a stubbed `gh`, not inferred from the source.
# A grep would still pass if the renderer call became unreachable, selected the
# wrong mode, or stopped reporting a render failure as `unknown`.
#
# One hazard is asserted statically because it is about the OTHER file:
# status.sh's pre-manifest fallback scrapes setup-github-labels.sh for literal
# `name|color|description` lines, and after this rewrite there are none left — so
# that scrape now yields an EMPTY set, which is why reaching it with a manifest
# present would report a fully seeded repo as unseeded.
status_script="scripts/status.sh"
if [ -f "$status_script" ]; then
    scraped="$(sed -n -E 's/^([A-Za-z0-9:._-]+)\|[0-9A-Fa-f]{6}\|.*/\1/p' "$labels_script")"
    [ -z "$scraped" ] ||
        fail "$labels_script still carries literal label line(s) [$(echo "$scraped" | tr '\n' ' ')] — the manifest is meant to be the only source, and a surviving hand-list can fork from it"
    echo "PASS: $labels_script carries no literal label lines, so the pre-manifest scrape is now empty"

    # build_status_fixture NAME — a repo root holding status.sh, the label
    # machinery, and a git remote, plus a `gh` stub on PATH answering only what
    # the setup audit needs. Everything else the fan-out calls returns `[]`,
    # which status.sh already treats as "nothing to report" for those checks.
    build_status_fixture() {
        fx="${test_tmp}/status-$1"
        rm -rf "$fx"
        mkdir -p "$fx/root/scripts" "$fx/bin"
        cp "$status_script" "$labels_script" "$renderer" "$agent_renderer" "$validator" \
            "$fx/root/scripts/"
        cp "$registry" "$schema" agent-registry.json "$fx/root/"
        git -C "$fx/root" init -q
        git -C "$fx/root" remote add origin https://github.com/acme/widget.git
        : >"$fx/labels.txt"
        cat >"$fx/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
"auth status") exit 0 ;;
"repo view") printf '%s\n' '{"nameWithOwner":"acme/widget","visibility":"PRIVATE","isPrivate":true}'; exit 0 ;;
esac
if [ "\$1" = api ]; then
    case "\$2" in
    *"/labels") cat "$fx/labels.txt"; exit 0 ;;
    esac
fi
printf '%s\n' '[]'
exit 0
STUB
        chmod +x "$fx/bin/gh"
    }

    # The live label set the fixture's repo will appear to have.
    seed_status_fixture() {
        printf '%s\n' "$1" >"$fx/labels.txt"
    }

    # Returns status.sh's "Starter labels" line, colors stripped.
    run_status_fixture() {
        PATH="$fx/bin:$PATH" NO_COLOR=1 NETWORK_TIMEOUT=2 \
            bash "$fx/root/scripts/status.sh" setup 2>/dev/null |
            sed -E 's/\x1b\[[0-9;]*m//g' | grep -i 'Starter labels' || true
    }

    expect_status() {
        local description="$1" expected="$2" line
        line="$(run_status_fixture)"
        case "$line" in
        *"$expected"*) ;;
        *) fail "$description: expected a Starter labels line containing '$expected', got '${line:-<none>}'" ;;
        esac
        echo "PASS: status reports $description"
    }

    provision_names="$(printf '%s\n' "$rendered_provision" | sed -n 's/|.*//p')"
    all_names="$rendered_names"
    provision_count="$(count_lines "$provision_names")"
    all_count="$(count_lines "$all_names")"
    # The two modes must actually differ, or every mode-selection case below
    # would pass against a renderer that ignored its argument.
    [ "$all_count" -gt "$provision_count" ] ||
        fail "the foreman mode renders no more labels than provision ($all_count vs $provision_count) — the mode-selection cases below would prove nothing"

    # 6a. Manifest present, no foreman profile, every provisioned label live.
    # The count proves the mode too: expecting the `all` set here would report
    # the arming labels missing on a repo whose setup never creates them.
    build_status_fixture seeded
    seed_status_fixture "$provision_names"
    expect_status "a fully seeded non-foreman repo as complete" "all ${provision_count} seeded"

    # 6b. One label missing — the case the whole inventory exists for.
    build_status_fixture missing
    seed_status_fixture "$(printf '%s\n' "$provision_names" | tail -n +2)"
    expect_status "a repo missing one label" "1/${provision_count} missing"

    # 6c. Foreman profile — the arming axis joins the expected set.
    build_status_fixture foreman
    mkdir -p "$fx/root/taskfiles"
    : >"$fx/root/taskfiles/foreman.yml"
    seed_status_fixture "$all_names"
    expect_status "a foreman repo as complete over the full set" "all ${all_count} seeded"

    # 6d. An invalid manifest must be UNKNOWN, never "run setup". The renderer
    # refuses to render it, and a swallowed failure would look like an empty
    # expected set — i.e. a fully seeded repo reported as unseeded.
    build_status_fixture invalid
    seed_status_fixture "$provision_names"
    node --input-type=module - "$registry" "$fx/root/label-registry.json" <<'NODE'
import { readFile, writeFile } from 'node:fs/promises'
const [inputPath, outputPath] = process.argv.slice(2)
const registry = JSON.parse(await readFile(inputPath, 'utf8'))
delete registry.families[0].values
await writeFile(outputPath, `${JSON.stringify(registry, null, 2)}\n`)
NODE
    expect_status "an unrenderable manifest as unknown" "did not render"

    # 6e. Manifest present but the renderer missing — also unknown, never a
    # silent fall-through to the (now empty) scrape.
    build_status_fixture no-renderer
    seed_status_fixture "$provision_names"
    rm -f "$fx/root/scripts/label-registry-labels.mjs"
    expect_status "a missing renderer as unknown" "unavailable"

    # 6f. No manifest at all: the pre-manifest scrape still works, so a template
    # twin that has not adopted the taxonomy keeps its inventory.
    build_status_fixture no-manifest
    rm -f "$fx/root/label-registry.json"
    cat >"$fx/root/scripts/setup-github-labels.sh" <<'LEGACY'
#!/usr/bin/env bash
# A pre-manifest provisioning script: the vocabulary is a literal table.
labels="
sec|5319E7|Security concern
blocked|E36209|Blocked by a non-issue dependency (reason in a comment)
"
LEGACY
    # The pre-manifest inventory is the scrape PLUS the agent registry's own
    # renderer (suggest:/claim:/foreman:, which were never literal lines), with
    # the arming prefix filtered off for a non-foreman profile — so seed all of
    # it, or this case would report the composed families as missing and prove
    # only that the fixture is incomplete.
    legacy_expected="$(
        printf 'sec\nblocked\n'
        node "$agent_renderer" all | sed -n 's/|.*//p' | grep -v '^foreman:'
    )"
    seed_status_fixture "$legacy_expected"
    expect_status "a manifest-less repo from the legacy scrape" \
        "all $(count_lines "$legacy_expected") seeded"
else
    echo "note: no $status_script in this profile — skipping the status-inventory binding" >&2
fi

echo "label registry tests OK"
