#!/usr/bin/env bash
# test-guarded-update.sh — tests for assets/guarded-update.sh (harmon-devkit#420).
#
# The prepare and discover assertions moved here from scripts/test-skills.sh
# with the code they cover (#2041), names unchanged; guarded-update-assertions.tsv
# records where every update-procedure assertion lives. Most still read the
# whole procedure — the update references with the asset in the place its steps
# ran — so an assertion that counts across the procedure keeps counting every
# occurrence. The fixture cases at the end run the asset itself, offline, against
# a throwaway harmon-init and target repository. Run through `task test:skills`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
STANDARDIZE_ASSETS="$repo/ai/skills/repo/standardize-repo/assets"
STANDARDIZE_REFS="$repo/ai/skills/repo/standardize-repo/references"
GUARDED_UPDATE="$STANDARDIZE_ASSETS/guarded-update.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
}
expect_ok() {
    local desc="$1"
    local output
    shift
    if output="$("$@" 2>&1)"; then
        ok "$desc"
    else
        bad "$desc (expected exit 0)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}
expect_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$desc (expected non-zero exit)"; else ok "$desc"; fi
}
expect_fail_contains() {
    local desc="$1"
    local needle="$2"
    local output
    shift 2
    if output="$("$@" 2>&1)"; then
        bad "$desc (expected non-zero exit)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif grep -qF "$needle" <<<"$output"; then
        ok "$desc"
    else
        bad "$desc (missing diagnostic: $needle)"
        [ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}
git_init() { git init -q -b main "$1"; }
git_commit_all() {
    git -C "$1" add -A
    git -C "$1" -c user.email=test@example.com -c user.name=test \
        -c commit.gpgsign=false commit -q -m "$2"
}

echo "==> guarded update asset"
UPDATE_PROCEDURE="$TMPROOT/mode-update-procedure.md"
cat "$STANDARDIZE_REFS/mode-update-basics.md" "$GUARDED_UPDATE" \
    "$STANDARDIZE_REFS"/mode-update-{preflight,execution,conflicts,verification,handoff,github}.md >"$UPDATE_PROCEDURE"
standardize_reference() {
    if [ "$1" = mode-update.md ]; then
        printf '%s\n' "$UPDATE_PROCEDURE"
    else
        printf '%s/%s\n' "$STANDARDIZE_REFS" "$1"
    fi
}
expect_ok "update guidance starts from the recorded CodeRabbit answer" \
    grep -qF ".use_coderabbit // false' .copier-answers.yml" \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance starts from the recorded Codex cloud answer" \
    grep -qF ".use_codex_cloud_review // false' .copier-answers.yml" \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance reviews the Codex controller and conditional option" \
    sh -c 'grep -qF "use_foreman use_codex_review use_codex_cloud_review" "$1" &&
        grep -qF "use_foreman use_codex_review use_skills_sync" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance rejects missing Codex classifier prerequisites" \
    sh -c 'grep -qF "use_codex_cloud_review requires use_skills_sync" "$1" &&
        grep -qF "use_codex_cloud_review requires the universal skill category" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Inventory every package recursively; procedure references can be bare names.
procedure_assets_accounted_for() {
    python3 - "$@" <<'PY_CHECK'
import re
import sys
from pathlib import Path

guidance, root, minimum, *procedures = sys.argv[1:]
root = Path(root)
text = "\n".join(Path(p).read_text() for p in procedures)
lines = [line.lstrip() for line in Path(guidance).read_text().splitlines()]
accounted = set()
exclusions = set()
in_block = False
blocks = 0
for line in lines:
    if line == "# BEGIN unprobed procedure assets":
        if in_block:
            sys.exit("nested exclusion block")
        in_block = True
        blocks += 1
    elif line == "# END unprobed procedure assets":
        if not in_block:
            sys.exit("unexpected exclusion block end")
        in_block = False
    elif in_block:
        match = re.fullmatch(r"# ([A-Za-z0-9._-]+/assets/[A-Za-z0-9._/-]+) — .+", line)
        if not match or any(part in ("", ".", "..") for part in match.group(1).split("/")):
            sys.exit(f"malformed exclusion: {line}")
        exclusions.add(match.group(1))
    else:
        match = re.fullmatch(r'SKILLS_SOURCE_(?:CLASSIFIER|MARKER)="ai/skills/universal/([^"]+)"', line)
        if match:
            accounted.add(match.group(1))
if blocks != 1 or in_block:
    sys.exit("missing or unterminated exclusion block")

def mentioned(name):
    return re.search(r'(?<![A-Za-z0-9._-])' + re.escape(name) + r'(?![A-Za-z0-9_-]|\.[A-Za-z0-9._-])', text) is not None

# Resolve explicit prescriptions before inventorying files: missing files cannot
# appear in the inventory. Bare assets/ references may name a sibling package;
# qualified paths and support_dir references identify their package explicitly.
asset_ref = re.compile(
    r'(?<![A-Za-z0-9_.-])(?:(?P<pkg>[A-Za-z0-9_-]+)/)?assets/'
    r'(?P<name>[A-Za-z0-9_-][A-Za-z0-9_./-]*\.[A-Za-z0-9]+)'
    r'(?![A-Za-z0-9_-]|\.[A-Za-z0-9._-])'
)
support_ref = re.compile(
    r'\$\{?support_dir\}?/(?P<name>[A-Za-z0-9_-][A-Za-z0-9_./-]*\.[A-Za-z0-9]+)'
    r'(?![A-Za-z0-9_-]|\.[A-Za-z0-9._-])'
)
for match in asset_ref.finditer(text):
    name, pkg = match.group('name', 'pkg')
    if pkg and match.start() > 0 and text[match.start() - 1] == '$':
        pkg = {'skill_dir': 'integrate', 'implement_dir': 'implement'}.get(pkg, pkg)
    candidates = [root / pkg / 'assets' / name] if pkg else list(root.glob(f'*/assets/{name}'))
    if not any(path.is_file() for path in candidates):
        sys.exit(f"missing prescribed asset: {match.group(0)}")
for match in support_ref.finditer(text):
    if not (root / 'dev-flow-support' / 'assets' / match.group('name')).is_file():
        sys.exit(f"missing prescribed asset: {match.group(0)}")

for entry in sorted(exclusions):
    path = root / entry
    if not path.is_file() or not mentioned(path.name):
        sys.exit(f"stale exclusion: {entry}")
accounted |= exclusions
found = []
for path in sorted(root.glob('*/assets/**/*')):
    if not path.is_file() or path.name.startswith('test-'):
        continue
    if any(part in ('__pycache__', '.cache', 'node_modules') for part in path.parts) or path.suffix in ('.pyc', '.pyo') or path.name.endswith('~'):
        continue
    if mentioned(path.name):
        asset = path.relative_to(root).as_posix()
        found.append(asset)
        if asset not in accounted:
            sys.exit(f"unaccounted procedure asset: {asset}")
print(f"prescribed assets: {len(found)}")
if len(found) < int(minimum):
    sys.exit(f"too few prescribed assets: {len(found)} (minimum {minimum})")
PY_CHECK
}
procedure_files=("$repo/ai/skills/universal/integrate/SKILL.md")
if [ -f "$repo/ai/skills/universal/shepherd/SKILL.md" ]; then
    procedure_files+=("$repo/ai/skills/universal/shepherd/SKILL.md")
fi
assets_root="$repo/ai/skills/universal"
# There are 24 today; 20 allows a few intentional removals without masking a broken inventory.
expect_ok "procedure assets are probed or explicitly excluded" \
    procedure_assets_accounted_for "$UPDATE_PROCEDURE" "$assets_root" 20 "${procedure_files[@]}"
# Mutate copies of the real inventory so every case retains the minimum and valid exclusions.
probe_root="$TMPROOT/probe-assets"
cp -R "$assets_root" "$probe_root"
cp "$UPDATE_PROCEDURE" "$TMPROOT/probe-guidance.md"
cat "${procedure_files[@]}" >"$TMPROOT/probe-procedure.md"
mkdir -p "$probe_root/integrate/assets/lib" "$probe_root/other/assets"
touch "$probe_root/integrate/assets/lib/new-probe.sh"
printf '\nnew-probe.sh\n' >>"$TMPROOT/probe-procedure.md"
expect_fail_contains "nested procedure asset requires a decision" 'unaccounted procedure asset: integrate/assets/lib/new-probe.sh' \
    procedure_assets_accounted_for "$TMPROOT/probe-guidance.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md"
rm "$probe_root/integrate/assets/lib/new-probe.sh"
touch "$probe_root/other/assets/new-other.sh"
printf '\nnew-other.sh\n' >>"$TMPROOT/probe-procedure.md"
expect_fail_contains "other package procedure asset requires a decision" 'unaccounted procedure asset: other/assets/new-other.sh' \
    procedure_assets_accounted_for "$TMPROOT/probe-guidance.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md"
rm "$probe_root/other/assets/new-other.sh"
for missing_ref in 'assets/never-added.sh' 'other/assets/new-other.sh' '$support_dir/never-added.sh'; do
    printf '\n%s\n' "$missing_ref" >"$TMPROOT/probe-missing.md"
    expect_fail_contains "missing prescribed asset $missing_ref fails" "missing prescribed asset: $missing_ref" \
        procedure_assets_accounted_for "$TMPROOT/probe-guidance.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md" "$TMPROOT/probe-missing.md"
done
touch "$probe_root/other/assets/new-helper.sh"
printf '\nRun new-helper.sh.\n' >>"$TMPROOT/probe-procedure.md"
expect_fail_contains "sentence-ending punctuation marks an asset mention" 'unaccounted procedure asset: other/assets/new-helper.sh' \
    procedure_assets_accounted_for "$TMPROOT/probe-guidance.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md"
rm "$probe_root/other/assets/new-helper.sh"
touch "$probe_root/other/assets/flow-exit.mjs"
expect_ok "asset names match whole tokens" \
    procedure_assets_accounted_for "$TMPROOT/probe-guidance.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md"
sed 's|# END unprobed procedure assets|# other/assets/missing.sh — stale fixture\
# END unprobed procedure assets|' "$TMPROOT/probe-guidance.md" >"$TMPROOT/probe-stale.md"
expect_fail_contains "stale exclusion fails" 'stale exclusion: other/assets/missing.sh' \
    procedure_assets_accounted_for "$TMPROOT/probe-stale.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md"
sed 's|# END unprobed procedure assets|# malformed entry\
# END unprobed procedure assets|' "$TMPROOT/probe-guidance.md" >"$TMPROOT/probe-malformed.md"
expect_fail_contains "malformed exclusion fails" 'malformed exclusion:' \
    procedure_assets_accounted_for "$TMPROOT/probe-malformed.md" "$probe_root" 20 "$TMPROOT/probe-procedure.md"
expect_fail_contains "minimum inventory fails closed" 'too few prescribed assets:' \
    procedure_assets_accounted_for "$TMPROOT/probe-guidance.md" "$probe_root" 999 "$TMPROOT/probe-procedure.md"
# Both narrative references must name exactly the asset paths selected by the variables.
probe_names_match() {
    local guidance="$1" doc="$2" paths="$TMPROOT/probe-paths" actual="$TMPROOT/probe-doc-paths"
    sed -En 's/^[[:space:]]*SKILLS_SOURCE_(CLASSIFIER|MARKER)="([^"]*)"$/\2/p' "$guidance" | sort -u >"$paths"
    grep -oE 'ai/skills/universal/[A-Za-z0-9_.-]+/assets/[A-Za-z0-9_./-]+' "$doc" | sort -u >"$actual"
    [ "$(wc -l <"$paths")" -eq 2 ] && cmp -s "$paths" "$actual"
}
for probe_doc in mode-audit.md standards-catalog.md; do
    expect_ok "$probe_doc names the update guidance probe set" \
        probe_names_match "$UPDATE_PROCEDURE" "$(standardize_reference "$probe_doc")"
done
expect_ok "update guidance waives classifier prerequisites for a skills-source repo" \
    sh -c 'grep -qF "SKILLS_SOURCE_CLASSIFIER=" "$1" &&
        grep -qF "ai/skills/universal/integrate/assets/check-codex-cloud-review.sh" "$1" &&
        grep -qF "SHIPS_CLASSIFIER_NATIVELY=true" "$1" &&
        grep -qF "git ls-files --stage -- \"\$SKILLS_SOURCE_CLASSIFIER\"" "$1" &&
        grep -qF "= \"100755\"" "$1" &&
        grep -qF "SHIPS_CLASSIFIER_NATIVELY\" != \"true\"" "$1" &&
        grep -qF "waives both the skills-sync and universal-category" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Each waiver site is pinned through its own distinctive neighbour instead of a
# file-wide occurrence count. The counts these replace (`-eq 6` on
# SHIPS_CLASSIFIER_NATIVELY, `-eq 3` on the diagnostic) broke the moment the
# detector grew a line, and never said anything about WHERE the waiver applies:
# all three sites could collapse into one and the totals would still match.
# The windows are the asset's shfmt layout, where every one-line guard is a
# five-line brace group: the next guard, not any later one.
# shell-robustness: begin-exempt — the pipeline runs in a `sh -c`/`bash -c` subshell that never enables pipefail
expect_ok "update guidance waives skills-sync at the pre-review guard site" \
    sh -c 'grep -A12 -F "$2" "$1" | grep -qF "$3"' sh \
    "$UPDATE_PROCEDURE" \
    'USE_SKILLS_SYNC must be true or false' \
    'requires use_skills_sync (waived when this repo ships the classifier natively'
expect_ok "update guidance waives skills-sync at the post-review guard site" \
    sh -c 'grep -A12 -F "$2" "$1" | grep -qF "$3"' sh \
    "$UPDATE_PROCEDURE" \
    'reviewed use_skills_sync must be boolean' \
    'requires use_skills_sync (waived when this repo ships the classifier natively'
expect_ok "update guidance waives the universal category at its own guard site" \
    sh -c 'grep -A2 -F "$2" "$1" | grep -qF "$3"' sh \
    "$UPDATE_PROCEDURE" \
    'yq -e '"'"'contains(["universal"])'"'"' -' \
    'requires the universal skill category (waived when this repo ships the classifier natively'
expect_ok "update guidance keeps the skill_categories carve-out for a native classifier" \
    sh -c 'grep -B3 -F "$2" "$1" | grep -qF "$3"' sh \
    "$UPDATE_PROCEDURE" \
    'required skill_categories question is not active' \
    '[ "$SHIPS_CLASSIFIER_NATIVELY" != "true" ]'
# shell-robustness: end-exempt
# The detector is lifted out of the doc and RUN against throwaway repos below,
# so its marker pair has to stay unique file-wide: a second copy of either
# marker would widen the sed range and hand `bash -eu` a truncated program.
GU_CLASSIFIER_SNIPPET="$TMPROOT/classifier-detector.sh"
sed -n '/# >>> classifier-detector >>>/,/# <<< classifier-detector <<</p' \
    "$UPDATE_PROCEDURE" >"$GU_CLASSIFIER_SNIPPET"
expect_ok "classifier detector carries exactly one extraction marker pair" \
    sh -c 'test "$(grep -cF "# >>> classifier-detector >>>" "$1")" -eq 1 &&
        test "$(grep -cF "# <<< classifier-detector <<<" "$1")" -eq 1' sh \
    "$UPDATE_PROCEDURE"
# Marker drift extracts garbage silently — an empty range, or a range running to
# the end of the file — and every behavioral case below would then be testing
# whatever came out. Prove the extraction is a program before trusting it.
expect_ok "classifier detector extraction is non-empty and parses as bash" \
    sh -c 'test -s "$1" && bash -n "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET"
expect_ok "classifier detector validates the integrate entry point frontmatter" \
    sh -c 'grep -qF "ai/skills/universal/integrate/SKILL.md" "$1" &&
        grep -qF "git ls-files --error-unmatch" "$1" &&
        grep -qF "classifier_skill_frontmatter_ok" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET"
# Structure stays static because yq does not fail closed on it: a file with no
# frontmatter, or an unclosed block whose body is valid YAML, both parse and
# resolve `.name`. Only the fence checks remain hand-rolled.
expect_ok "classifier frontmatter probe checks the fences statically" \
    sh -c 'grep -qF "$2" "$1" && grep -qF "$3" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'NR == 1 && $0 != "---" { exit }' 'exit (fence >= 2) ? 0 : 1'
# Values come from a real parser. mode-update.md already hard-requires yq v4, so
# the detector may assume it, and the whole hand-written YAML grammar is gone.
expect_ok "classifier frontmatter probe resolves values with yq" \
    sh -c 'for needle in "$2" "$3" "$4" "$5"; do
        grep -qF "$needle" "$1" || exit 1
    done' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'yq --front-matter=extract -e' \
    '(.name | tag) == "!!str"' \
    '(.description | tag) == "!!str"' \
    '.description != ""'
# The grammar re-implementation must be GONE, not merely unused: each of these
# was a round of findings, and every one of them is the parser's job now.
expect_ok "classifier frontmatter probe reimplements no YAML grammar" \
    sh -c 'for needle in "$2" "$3" "$4" "$5" "$6" "$7"; do
        grep -qF "$needle" "$1" && exit 1
    done
    exit 0' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'in_block' 'ok_desc' 'seen_name' 'd != "null"' '\047shepherd\047' \
    'sub(/[[:space:]]#.*$/'
# verify-skills.sh stays canonical for LAYOUT; YAML semantics now come from the
# parser. Name it, so the next reader knows which side owns which question.
expect_ok "classifier frontmatter probe cross-references its canonical source" \
    sh -c 'grep -qF "$2" "$1" && grep -qF "$3" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'verify-skills.sh' 'frontmatter_is_closed'
# The entry point is mode-checked from the index, same idiom as the classifier
# path: only regular blobs qualify, so a 120000 symlink cannot stand in.
expect_ok "classifier detector requires a regular-file integrate entry point" \
    sh -c 'grep -qF "classifier_skill_is_regular_file" "$1" &&
        grep -qF "100644 | 100755" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET"
# The verb probes must anchor on the helper's dispatch arms, not on the usage
# strings a comment can print — that difference is the whole finding.
for cls_verb in reserve attach check show reap; do
    # shell-robustness: begin-exempt — the pipeline runs in a `sh -c`/`bash -c` subshell that never enables pipefail
    expect_ok "classifier detector anchors $cls_verb on a dispatch case arm" \
        sh -c 'grep -F "$2" "$1" | grep -qF classifier_code_has' sh \
        "$GU_CLASSIFIER_SNIPPET" "^$cls_verb\\)"
done
# And it must no longer anchor on anything a banner can print. Checked against
# the detector's own CODE, since its rationale comment quotes the old strings
# precisely to explain why they were abandoned.
expect_fail "classifier detector code no longer anchors on printable usage strings" \
    sh -c 'sed "s/^[[:space:]]*//" "$1" | grep -v "^#" | grep -qF -- "$2"' sh \
    "$GU_CLASSIFIER_SNIPPET" 'reserve --state'
# The exit-code pairs are the bounded-attempt lifecycle the integrator depends on,
# asserted as verdict+code pairs so neither half can drift away alone.
expect_ok "classifier detector anchors the pending and escalate exit contract" \
    sh -c 'for needle in "$2" "$3" "$4" "$5"; do
        grep -F "$needle" "$1" | grep -qF classifier_code_has || exit 1
    # shell-robustness: end-exempt
    done' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    '^emit pending ' '^exit 11$' '^emit escalate ' '^exit 13$'
# Comment stripping is what makes every probe above unsatisfiable by prose.
expect_ok "classifier detector reads helper code with comment lines stripped" \
    sh -c 'grep -qF "$2" "$1" && grep -qF "$3" "$1"' sh \
    "$GU_CLASSIFIER_SNIPPET" \
    'line ~ /^#/ { next }' 'ENVIRON["CLASSIFIER_PROBE"]'
# The probe pattern must not travel via `awk -v`, which escape-processes the
# value and would mangle the `\)` in every case-arm anchor.
expect_fail "classifier detector does not pass probe patterns through awk -v" \
    grep -qF -- 'awk -v' "$GU_CLASSIFIER_SNIPPET"
# Structural guard against reintroducing the pipefail hazard. `grep -q` exits at
# the first match, killing upstream pipeline stages with SIGPIPE; under
# `pipefail` that makes a matching probe report failure. Checked on the
# detector's CODE, since the rationale comment names the broken form on purpose.
expect_ok "classifier detector code contains no early-exit grep pipeline" \
    sh -c 'test "$(sed "s/^[[:space:]]*//" "$1" | grep -v "^#" | grep -c "grep -q")" -eq 0' sh \
    "$GU_CLASSIFIER_SNIPPET"
expect_fail "update guidance does not preseed reviewed skill categories" \
    grep -qF 'failed to seed reviewed skill categories' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance reads the reviewed CodeQL language matrix" \
    grep -qF "'.codeql_languages' \"\$REVIEWED_DATA\"" \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance rejects an empty enabled CodeQL matrix" \
    grep -qF 'CODEQL_LANGUAGES must be a nonempty YAML list' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance derives every newly introduced Copier question" \
    sh -c 'grep -qF "baseline-questions" "$1" &&
        grep -qF "target-questions" "$1" &&
        grep -qF "new-question-candidates" "$1" &&
        grep -qF "active-target-questions" "$1" &&
        grep -qF "active-new-questions" "$1" &&
        grep -qF "reviewed-keys" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance discovers recordable questions without running tasks" \
    sh -c 'grep -qF "copy --trust --defaults --skip-tasks" "$1" &&
        grep -qF "DISCOVERY_STABLE" "$1" &&
        grep -qF "active-reviewed-data.yml" "$1" &&
        grep -qF "inactive conditional" "$1" &&
        grep -qF "accepted only when every admitted key" "$1" &&
        grep -qF "never part of the answers discovery settles" "$1"' sh \
    "$UPDATE_PROCEDURE"

# Issue #1900: run the extracted discovery loop with real Copier against a
# template whose required question is gated on a reviewed answer. The loop is
# the implementation an operator pastes, so it is executed, not grepped.
GD_ROOT="$TMPROOT/gated-discovery"
GD_TEMPLATE="$GD_ROOT/template-src"
mkdir -p "$GD_TEMPLATE/template"
cat >"$GD_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Gated Discovery
use_claude_review:
  type: bool
  default: false
claude_review_actor_id:
  type: str
  default: ""
  when: "{{ use_claude_review }}"
  validator: >-
    {% if not claude_review_actor_id %}claude_review_actor_id is required
    when use_claude_review is true{% endif %}
EOF
cat >"$GD_TEMPLATE/template/.copier-answers.yml.jinja" <<'EOF'
{{ _copier_answers|to_nice_yaml -}}
EOF
git_init "$GD_TEMPLATE"
git_commit_all "$GD_TEMPLATE" "gated discovery template"
GD_LOOP="$GD_ROOT/discovery-loop.sh"
sed -n '/^[[:space:]]*# >>> active-question-discovery >>>$/,/^[[:space:]]*# <<< active-question-discovery <<<$/p' \
    "$UPDATE_PROCEDURE" >"$GD_LOOP"
expect_ok "update guidance marks exactly one active-question discovery loop" \
    sh -c 'test "$(grep -cx "[[:space:]]*# >>> active-question-discovery >>>" "$1")" -eq 1 &&
        test "$(grep -cx "[[:space:]]*# <<< active-question-discovery <<<" "$1")" -eq 1 &&
        grep -qF "DISCOVERY_STABLE=false" "$2"' sh \
    "$UPDATE_PROCEDURE" "$GD_LOOP"
# Old behaviour as a mutant: no reviewed key is ever admitted ahead of the
# active set, which is exactly the seeding the loop had before #1900.
GD_LOOP_OLD="$GD_ROOT/discovery-loop-old.sh"
sed "s/^\([[:space:]]*\)yq -r 'keys | \.\[\]' \"\$REVIEWED_DATA\" |\$/\1true |/" \
    "$GD_LOOP" >"$GD_LOOP_OLD"
expect_fail "the old-seeding mutant differs from the shipped loop" \
    cmp -s "$GD_LOOP" "$GD_LOOP_OLD"
gd_run() {
    # gd_run <loop> <case> <reviewed-yaml or "absent">
    local state="$GD_ROOT/$2"
    rm -rf "$state" && mkdir -p "$state/cache" &&
        printf '%s\n' 'project_name: Gated Discovery' 'use_claude_review: false' \
            >"$state/original-data.yml" &&
        if [ "$3" != absent ]; then printf '%s\n' "$3" >"$state/reviewed-data.yml"; fi &&
        {
            printf '%s\n' 'set -eu'
            sed -n '/^run_guarded_copier() {/,/^}/p' "$UPDATE_PROCEDURE"
            cat "$1"
            printf '%s\n' 'printf "%s\n" "$TARGET_DISCOVERY" >"$GUARDED_STATE/accepted-render"'
        } >"$state/run.sh" &&
        env GUARDED_STATE="$state" \
            REVIEWED_DATA="$state/reviewed-data.yml" \
            ORIGINAL_DATA="$state/original-data.yml" \
            HARMON_INIT_COMMIT="$(git -C "${GD_SRC:-$GD_TEMPLATE}" rev-parse HEAD)" \
            HARMON_INIT_SOURCE="${GD_SRC:-$GD_TEMPLATE}" \
            GUARDED_TEMPLATE="${GD_SRC:-$GD_TEMPLATE}" \
            GUARDED_COPIER_CACHE="$state/cache" \
            sh "$state/run.sh"
}
GD_APPROVED=$'use_claude_review: true\nclaude_review_actor_id: "41898282"'
expect_fail_contains "old seeding fails on a gated required question the reviewed data answers" \
    "target question discovery failed" \
    gd_run "$GD_LOOP_OLD" old-approved "$GD_APPROVED"
expect_ok "discovery converges when reviewed data answers a gated required question" \
    gd_run "$GD_LOOP" approved "$GD_APPROVED"
expect_ok "converged discovery activates the gated question with its reviewed value" \
    sh -c 'grep -qxF claude_review_actor_id "$1/active-target-questions" &&
        test "$(yq -r ".claude_review_actor_id" "$1/discovery-data.yml")" = 41898282 &&
        test "$(yq -r ".claude_review_actor_id" "$(cat "$1/accepted-render")/.copier-answers.yml")" = 41898282' sh \
    "$GD_ROOT/approved"
expect_fail_contains "an unreviewed required question still stops discovery" \
    "Validation error for question 'claude_review_actor_id'" \
    gd_run "$GD_LOOP" unreviewed 'use_claude_review: true'
expect_fail_contains "an unreviewed required question names the fix" \
    "add an approved value for that question" \
    gd_run "$GD_LOOP" unreviewed-fix 'use_claude_review: true'
expect_ok "discovery converges with a stale reviewed value for an inactive question" \
    gd_run "$GD_LOOP" stale $'use_claude_review: false\nclaude_review_actor_id: "41898282"'
expect_fail "an accepted render never carries an inactive question's reviewed value" \
    sh -c 'grep -qxF claude_review_actor_id "$1/active-target-questions" ||
        yq -e "has(\"claude_review_actor_id\")" "$1/discovery-data.yml"' sh \
    "$GD_ROOT/stale"
expect_ok "discovery without reviewed data renders the recorded answers" \
    gd_run "$GD_LOOP" first-run absent
# Two required questions behind one gate, and reviewed data answers only the
# first: the stop must name the one still missing, not the answered one that
# the prior-active-only fallback has to leave out (challenge r1 finding).
GD_TEMPLATE_TWO="$GD_ROOT/template-two-src"
mkdir -p "$GD_TEMPLATE_TWO/template"
cp "$GD_TEMPLATE/copier.yml" "$GD_TEMPLATE_TWO/copier.yml"
cat >>"$GD_TEMPLATE_TWO/copier.yml" <<'EOF'
claude_review_actor_login:
  type: str
  default: ""
  when: "{{ use_claude_review }}"
  validator: >-
    {% if not claude_review_actor_login %}claude_review_actor_login is required
    when use_claude_review is true{% endif %}
EOF
cp "$GD_TEMPLATE/template/.copier-answers.yml.jinja" "$GD_TEMPLATE_TWO/template/"
git_init "$GD_TEMPLATE_TWO"
git_commit_all "$GD_TEMPLATE_TWO" "two gated required questions"
GD_SRC="$GD_TEMPLATE_TWO"
expect_fail_contains "a partly answered gate names the question still missing" \
    "Validation error for question 'claude_review_actor_login'" \
    gd_run "$GD_LOOP" two-partial "$GD_APPROVED"
unset GD_SRC
expect_fail "update guidance never hard-codes Foreman off" \
    grep -qF -- '--data use_foreman=false' "$UPDATE_PROCEDURE"
expect_ok "update guidance refreshes the origin/main tracking ref explicitly" \
    grep -qF '+refs/heads/main:refs/remotes/origin/main' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance requires the canonical recorded source" \
    grep -qF '_src_path must be the canonical harmon-init URL before update' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance freezes the verified release commit" \
    grep -qF 'HARMON_INIT_COMMIT="$(git -C ~/git/harmon-init rev-parse' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance freezes the recorded baseline commit" \
    grep -qF 'RECORDED_COMMIT="$(git -C ~/git/harmon-init rev-parse' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance rejects recorded baselines before v3" \
    grep -qF '"$V3_BASELINE_COMMIT" "$RECORDED_COMMIT"' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance routes pre-v3 lineage to adoption" \
    grep -qF 'recorded baseline predates v3' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance requires the target to descend from the baseline" \
    grep -qF '"$RECORDED_COMMIT" "$HARMON_INIT_COMMIT"' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance requires explicit legacy baseline recovery approval" \
    grep -qF 'ACCEPT_LEGACY_BASELINE:?obtain maintainer approval' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance accepts commit-targeted legacy releases" \
    grep -qF '"$RECORDED_COMMIT") ;;' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance accepts main-targeted legacy releases" \
    grep -qF 'recorded tag is not on the release target branch' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance freezes an offline read-only clone" \
    sh -c 'grep -qF "remote remove origin" "$1" &&
        grep -qF "chmod -R a-w" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance snapshots from the canonical remote" \
    grep -qF 'git clone --no-checkout "$HARMON_INIT_SOURCE"' \
    "$UPDATE_PROCEDURE"
expect_fail "update guidance does not snapshot local-only tags" \
    grep -qF 'git clone --no-local --no-checkout ~/git/harmon-init' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance rejects remote-capable template submodules" \
    grep -qF '"$GUARDED_COMMIT:.gitmodules"' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance ignores recovery state in ordinary and linked worktrees" \
    sh -c 'grep -qF "GUARDED_STATE=.copier-guarded-update" "$1" &&
        grep -qF "git rev-parse --path-format=absolute --git-path info/exclude" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance refuses to overwrite interrupted guarded state" \
    grep -qF 'recover or remove it before retrying' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance process-scopes canonical URL rewrites" \
    sh -c 'grep -qF "GIT_CONFIG_COUNT=2" "$1" &&
        grep -qF "insteadOf" "$1" &&
        grep -qF "run_guarded_copier" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Every `comm` in the guarded-update recipe reads files a `LC_ALL=C sort -u`
# produced. Left unpinned it re-derives the ordering under whatever locale the
# copying shell happens to carry — a UTF-8 collation orders `_` against letters
# differently than byte order does — then rejects its own input with `file 1 is
# not in sorted order` and exits 1 straight into the snippet's `|| { …; exit 1;
# }` handler. Counting instead of asserting a literal keeps the invariant true
# as sites are added: an unpinned newcomer moves one total and not the other.
expect_ok "update guidance pins collation on every comm invocation" \
    sh -c 'total="$(grep -cE "comm -[0-9]" "$1")"
        pinned="$(grep -cE "LC_ALL=C comm -[0-9]" "$1")"
        test "$total" -gt 0 && test "$total" -eq "$pinned"' sh \
    "$UPDATE_PROCEDURE"
# The reviewed-keyset probe runs on the designed first pass, where
# $REVIEWED_DATA does not exist yet. Folding its `test -e` guard into the
# command substitution made the assignment inherit exit 1, so a `bash -eu` shell
# died before the gate below it could reach the seeding block that gate exists
# to trigger — after the expensive discovery loop, and for no reason.
# shell-robustness: begin-exempt — the pipeline runs in a `sh -c`/`bash -c` subshell that never enables pipefail
expect_ok "update guidance keeps the reviewed-keyset probe errexit-safe" \
    sh -c 'grep -qF "REVIEWED_KEYSET_OID=\"\"" "$1" &&
        ! grep -A1 -F "REVIEWED_KEYSET_OID=\"\$(" "$1" |
            grep -qE "^[[:space:]]*test -e"' sh \
    "$UPDATE_PROCEDURE"
# shell-robustness: end-exempt
# The check moved into prepare, where it is a step of the subcommand function
# (one shfmt indent); the preview and apply are still top-level Markdown steps.
expect_ok "update check, preview, and apply use the guarded Copier wrapper" \
    test "$(($(grep -Ec '^(if )?run_guarded_copier (check-update|update)' \
        "$UPDATE_PROCEDURE") + $(grep -Ec '^    run_guarded_copier check-update' \
            "$GUARDED_UPDATE")))" -eq 3
expect_ok "update guidance runs drift only after guarded source creation" \
    test "$(grep -nF 'GUARDED_TEMPLATE="$(mktemp' \
        "$UPDATE_PROCEDURE" | cut -d: -f1)" -lt \
    "$(grep -nF 'assets/diff-template.sh .' \
        "$UPDATE_PROCEDURE" | head -1 | cut -d: -f1)"
expect_ok "update guidance gates on a release supporting CodeRabbit selection" \
    grep -qF "grep -q '^use_coderabbit:'" \
    "$UPDATE_PROCEDURE"
expect_ok "every update Copier run pins the same immutable release commit" \
    test "$(grep -Fc -- '--vcs-ref="$HARMON_INIT_COMMIT"' \
        "$UPDATE_PROCEDURE")" -eq 5
expect_fail "update commands do not reuse the mutable release tag" \
    grep -qF -- '--vcs-ref="$HARMON_INIT_REF"' "$UPDATE_PROCEDURE"
expect_ok "update guidance probes gh before the legacy release lookup" \
    sh -c 'grep -qF "legacy baseline recovery requires the gh CLI on PATH" "$1" &&
        grep -qF "requires authenticated gh; run gh auth login" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance detects a missing release by HTTP status" \
    grep -qF "grep -q 'HTTP 404'" \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance reports a release API failure distinctly" \
    grep -qF 'cannot read the GitHub release record for' \
    "$UPDATE_PROCEDURE"
GU_VARS="$TMPROOT/guarded-render-vars"
mkdir -p "$GU_VARS"
sed -n '/^[[:space:]]*# >>> guarded-render-variables >>>$/,/^[[:space:]]*# <<< guarded-render-variables <<<$/p' \
    "$UPDATE_PROCEDURE" >"$GU_VARS/resolve.sh"
printf '%s\n' 'use_codeql: false' >"$GU_VARS/.copier-answers.yml"
expect_ok "guarded render variables derive false CodeQL from answers" \
    sh -c 'cd "$1" && unset USE_CODEQL && REVIEWED_DATA=absent \
        SHIPS_CLASSIFIER_NATIVELY=false && . ./resolve.sh && \
        test "$USE_CODEQL" = false && test "$CODEQL_LANGUAGES" = "[]"' sh "$GU_VARS"
printf '%s\n' '{}' >"$GU_VARS/.copier-answers.yml"
expect_fail "guarded render variables reject missing CodeQL answer" \
    sh -c 'cd "$1" && unset USE_CODEQL && REVIEWED_DATA=absent \
        SHIPS_CLASSIFIER_NATIVELY=false && . ./resolve.sh' sh "$GU_VARS"
printf '%s\n' 'use_codeql: "false"' >"$GU_VARS/.copier-answers.yml"
expect_fail "guarded render variables reject nonboolean CodeQL answer" \
    sh -c 'cd "$1" && unset USE_CODEQL && REVIEWED_DATA=absent \
        SHIPS_CLASSIFIER_NATIVELY=false && . ./resolve.sh' sh "$GU_VARS"
expect_ok "guarded render variables honor explicit CodeQL override" \
    sh -c 'cd "$1" && USE_CODEQL=false REVIEWED_DATA=absent \
        SHIPS_CLASSIFIER_NATIVELY=false && . ./resolve.sh && \
        test "$USE_CODEQL" = false' sh "$GU_VARS"
# ── the asset itself, offline (#2041) ─────────────────────────────────
# A throwaway harmon-init stands in for the canonical remote: process-scoped
# `insteadOf` rewrites both canonical URL spellings to it, the same mechanism
# run_guarded_copier uses for the offline snapshot, and HOME holds the
# ~/git/harmon-init checkout prepare refreshes. TMPDIR keeps every mktemp the
# asset makes inside TMPROOT; the snapshot is read-only, hence the chmod.
trap 'chmod -R u+w "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
FX="$TMPROOT/fixture"
FX_ORIGIN="$FX/harmon-init"
FX_TARGET="$FX/target"
mkdir -p "$FX_ORIGIN/template" "$FX/home/git" "$FX/tmp"
cat >"$FX_ORIGIN/copier.yml" <<'EOF'
_subdirectory: template
project_name:
  type: str
  default: Fixture
use_foreman:
  type: bool
  default: false
use_codex_review:
  type: bool
  default: false
use_codex_cloud_review:
  type: bool
  default: false
  when: "{{ use_codex_review }}"
use_skills_sync:
  type: bool
  default: false
skill_categories:
  type: str
  multiselect: true
  choices: [universal, repo]
  default: []
  when: "{{ use_skills_sync }}"
use_coderabbit:
  type: bool
  default: false
use_codeql:
  type: bool
  default: false
codeql_languages:
  type: str
  multiselect: true
  choices: [javascript-typescript, python]
  default: []
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' >"$FX_ORIGIN/template/.copier-answers.yml.jinja"
printf '%s\n' '# {{ project_name }}' >"$FX_ORIGIN/template/README.md.jinja"
git_init "$FX_ORIGIN"
git_commit_all "$FX_ORIGIN" "v3 migration boundary"
git -C "$FX_ORIGIN" tag v3.0.0
printf '%s\n' '' 'Baseline release.' >>"$FX_ORIGIN/template/README.md.jinja"
git_commit_all "$FX_ORIGIN" "recorded baseline"
FX_BASELINE="$(git -C "$FX_ORIGIN" rev-parse HEAD)"
cat >>"$FX_ORIGIN/copier.yml" <<'EOF'
new_flag:
  type: bool
  default: false
EOF
git_commit_all "$FX_ORIGIN" "target release adds a question"
git -C "$FX_ORIGIN" tag v9.0.0
FX_TARGET_COMMIT="$(git -C "$FX_ORIGIN" rev-parse HEAD)"
git clone -q "$FX_ORIGIN" "$FX/home/git/harmon-init"
git_init "$FX_TARGET"
printf '%s\n' '# Fixture' '' 'Baseline release.' >"$FX_TARGET/README.md"
cat >"$FX_TARGET/.copier-answers.yml" <<EOF
_commit: $FX_BASELINE
_src_path: https://github.com/evanharmon1/harmon-init
codeql_languages: []
project_name: Fixture
use_codeql: false
use_coderabbit: false
use_codex_review: false
use_foreman: false
use_skills_sync: false
EOF
git_commit_all "$FX_TARGET" "rendered at the recorded baseline"
fx_run() { # fx_run <guarded-update args...>, from the target repository
    (cd "$FX_TARGET" && env HOME="$FX/home" TMPDIR="$FX/tmp" \
        GIT_CONFIG_COUNT=2 \
        "GIT_CONFIG_KEY_0=url.$FX_ORIGIN.insteadOf" \
        "GIT_CONFIG_VALUE_0=https://github.com/evanharmon1/harmon-init.git" \
        "GIT_CONFIG_KEY_1=url.$FX_ORIGIN.insteadOf" \
        "GIT_CONFIG_VALUE_1=https://github.com/evanharmon1/harmon-init" \
        "$@")
}
FX_STATE="$FX_TARGET/.copier-guarded-update"
state_digest() { # every file under the state directory, by content
    (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(git hash-object "$f")"
    done)
}
expect_ok "prepare freezes both commits and writes the guarded state" \
    fx_run env HARMON_INIT_REF=v9.0.0 "$GUARDED_UPDATE" prepare
expect_ok "prepare persists the frozen baseline and target commits" \
    sh -c 'test "$(cat "$1/recorded-commit")" = "$2" &&
        test "$(cat "$1/target-commit")" = "$3" &&
        grep -qxF new_flag "$1/new-question-candidates" &&
        test -z "$(git -C "$4" status --porcelain)"' sh \
    "$FX_STATE" "$FX_BASELINE" "$FX_TARGET_COMMIT" "$FX_TARGET"
FX_PREPARED="$(state_digest "$FX_STATE")"
expect_fail_contains "a prepare rerun over existing state refuses" \
    'already exists; recover or remove it before retrying' \
    fx_run env HARMON_INIT_REF=v9.0.0 "$GUARDED_UPDATE" prepare
expect_ok "the refused prepare rerun overwrote no guarded state" \
    test "$(state_digest "$FX_STATE")" = "$FX_PREPARED"
expect_ok "the loader restores a prepared state and runs the guarded copier" \
    fx_run bash -c 'set -eu
        . "$1" load
        grep -q "^copier " <<<"$(run_guarded_copier --version)"
        test "$HARMON_INIT_COMMIT" = "$2" && test "$RECORDED_COMMIT" = "$3"
        test -d "$GUARDED_TEMPLATE" && test -d "$GUARDED_COPIER_CACHE"' bash \
    "$GUARDED_UPDATE" "$FX_TARGET_COMMIT" "$FX_BASELINE"
expect_fail_contains "discover stops while a new question awaits review" \
    'replace all __REVIEW_REQUIRED__ values, then rerun discovery' \
    fx_run "$GUARDED_UPDATE" discover
expect_ok "discover seeds the sentinel instead of a default" \
    sh -c 'test "$(yq -r ".new_flag" "$1")" = __REVIEW_REQUIRED__ &&
        test "$(yq -r ".use_foreman" "$1")" = false' sh \
    "$FX_STATE/reviewed-data.yml"
FX_SEEDED="$(git hash-object "$FX_STATE/reviewed-data.yml")"
expect_fail_contains "a discover rerun refuses while the sentinel stands" \
    'review every existing entry and replace all __REVIEW_REQUIRED__ values' \
    fx_run "$GUARDED_UPDATE" discover
expect_ok "the refused discover rerun left the reviewed data unchanged" \
    test "$(git hash-object "$FX_STATE/reviewed-data.yml")" = "$FX_SEEDED"
yq -i '.new_flag = false' "$FX_STATE/reviewed-data.yml"
expect_ok "discover converges once every reviewed value is explicit" \
    fx_run "$GUARDED_UPDATE" discover
expect_ok "converged discover records the active review set and its render" \
    sh -c 'grep -qxF new_flag "$1/reviewed-keys" &&
        test -f "$(cat "$1/target-discovery-path")/.copier-answers.yml"' sh \
    "$FX_STATE"
expect_ok "the loader restores the reviewed answers and converged render" \
    fx_run bash -c 'set -eu
        . "$1" load
        grep -q "^copier " <<<"$(run_guarded_copier --version)"
        test "$USE_FOREMAN" = false && test "$CODEQL_LANGUAGES" = "[]"
        test "$REVIEWED_DATA" = .copier-guarded-update/reviewed-data.yml
        test -d "$TARGET_DISCOVERY"' bash \
    "$GUARDED_UPDATE"
# challenge-r1-codex-adversarial-1: a discover run that stops must not leave the
# previous run's render for load to restore. Put a sentinel back, rerun
# (refused), and the loader — even in a shell still holding the old value —
# leaves TARGET_DISCOVERY unset, as the Markdown's recovery reload did.
yq -i '.new_flag = "__REVIEW_REQUIRED__"' "$FX_STATE/reviewed-data.yml"
expect_fail_contains "a discover rerun with a sentinel back refuses" \
    'review every existing entry and replace all __REVIEW_REQUIRED__ values' \
    fx_run "$GUARDED_UPDATE" discover
expect_fail "a refused discover leaves no converged render path behind" \
    test -e "$FX_STATE/target-discovery-path"
expect_ok "the loader leaves TARGET_DISCOVERY unset after a refused discover" \
    fx_run bash -c 'set -eu
        TARGET_DISCOVERY="$2"
        . "$1" load
        test -z "${TARGET_DISCOVERY+x}"' bash \
    "$GUARDED_UPDATE" "$FX/stale-render"

# ── the assertion inventory ───────────────────────────────────────────
# Every assertion over the update procedure that existed when this asset was
# created is listed with the subcommand it covers (or `stays`) and the file it
# lives in; each name must be defined exactly once there, so moving an
# assertion without updating its row — or losing one — fails here.
inventory_holds() { # inventory_holds <tsv> [repository root]
    python3 - "${2:-$repo}" "$1" <<'PY_INVENTORY'
import re
import sys
from pathlib import Path

root, inventory = Path(sys.argv[1]), Path(sys.argv[2])
subcommands = {"prepare", "discover", "rehearse", "present", "apply",
               "reconcile", "promote", "rollback", "stays"}
moved = {"prepare", "discover"}
here = "ai/skills/repo/standardize-repo/assets/test-guarded-update.sh"
rows = [l.split("\t") for l in inventory.read_text().splitlines()
        if l and not l.startswith("#")]
problems = []
sources = {}
for row in rows:
    if len(row) != 3:
        problems.append(f"malformed row: {row}")
        continue
    name, sub, rel = row
    if sub not in subcommands:
        problems.append(f"unknown subcommand {sub!r}: {name}")
    if sub in moved and rel != here:
        problems.append(f"{sub} row not in the asset's tests: {name}")
    if rel not in sources:
        path = root / rel
        sources[rel] = path.read_text().splitlines() if path.is_file() else None
    if sources[rel] is None:
        problems.append(f"missing file {rel}: {name}")
        continue
    pattern = re.compile(r'\s*expect_\w+\s+"' + re.escape(name) + r'"(\s|$)')
    count = sum(1 for line in sources[rel] if pattern.match(line))
    if count != 1:
        problems.append(f"{name}: defined {count} times in {rel}")
names = [row[0] for row in rows if len(row) == 3]
if len(names) != len(set(names)):
    problems.append("duplicate inventory rows")
if problems:
    sys.exit("\n".join(problems))
print(f"{len(rows)} inventory rows hold")
PY_INVENTORY
}
GU_INVENTORY="$STANDARDIZE_ASSETS/guarded-update-assertions.tsv"
expect_ok "every inventoried assertion is defined exactly once where its row says" \
    inventory_holds "$GU_INVENTORY"
sed '1,/^[^#]/{/^[^#]/s/^/renamed /}' "$GU_INVENTORY" >"$TMPROOT/inventory-renamed.tsv"
expect_fail_contains "a listed assertion missing from its file fails the inventory" \
    'defined 0 times' inventory_holds "$TMPROOT/inventory-renamed.tsv"
GU_DUP_DIR="$TMPROOT/inventory-dup"
mkdir -p "$GU_DUP_DIR/ai/skills/repo/standardize-repo/assets"
printf '%s\n' 'expect_ok "duplicated name" true' 'expect_ok "duplicated name" true' \
    >"$GU_DUP_DIR/ai/skills/repo/standardize-repo/assets/test-guarded-update.sh"
printf '%s\t%s\t%s\n' 'duplicated name' discover \
    ai/skills/repo/standardize-repo/assets/test-guarded-update.sh >"$TMPROOT/inventory-dup.tsv"
expect_fail_contains "an assertion defined twice fails the inventory" \
    'defined 2 times' inventory_holds "$TMPROOT/inventory-dup.tsv" "$GU_DUP_DIR"

echo "guarded update tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
