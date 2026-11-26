#!/usr/bin/env bash
# test-guarded-update.sh — tests for assets/guarded-update.sh (harmon-devkit#420).
#
# The prepare and discover assertions (#2041) and the rehearse assertions (#2042)
# moved here from scripts/test-skills.sh with the code they cover, names
# unchanged; guarded-update-assertions.tsv
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
# The check moved into prepare (#2041), the preview and apply into the asset's
# preview and apply functions (#2043): all three are steps of subcommand
# functions now, and the Markdown starts no Copier update of its own.
expect_ok "update check, preview, and apply use the guarded Copier wrapper" \
    sh -c 'test "$(grep -Ec "^[[:space:]]+(if )?run_guarded_copier (check-update |update --trust --defaults (--pretend )?\\\\\$)" "$1")" -eq 3 &&
        ! grep -Eq "^[[:space:]]*(if )?(run_guarded_)?copier (check-update|update)" \
            "$2"/mode-update*.md' sh \
    "$GUARDED_UPDATE" "$STANDARDIZE_REFS"
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
# Shipped by both renders; the target declines it just before the rehearsal, so
# it is the one row the rehearsal below has to report (#2042).
printf '%s\n' 'Fixture notes.' >"$FX_ORIGIN/template/NOTES.md"
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
printf '%s\n' 'Fixture notes.' >"$FX_TARGET/NOTES.md"
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
    fx_run_in "$FX_TARGET" "$FX/tmp" "$@"
}
fx_run_in() { # fx_run_in <repository> <TMPDIR> <guarded-update args...>
    local dir="$1" tmp="$2"
    shift 2
    (cd "$dir" && env HOME="$FX/home" TMPDIR="$tmp" \
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
# ── rehearse, on the same fixture (#2042) ─────────────────────────────
# The entry-point guard (challenge-r1-codex-adversarial-1, -r2-…-1/-2) refuses
# before any Copier call or state write: the guarded state is unchanged and the
# run's private TMPDIR holds no copier-* directory. Each condition is proved on
# its own, so none is masked by another.
fx_rehearse_refused() { # fx_rehearse_refused <case> <expected message>
    local tmp="$FX/refusal-$1.tmp" before out
    mkdir "$tmp" && before="$(state_digest "$FX_STATE")" || return 1
    if out="$(fx_run_in "$FX_TARGET" "$tmp" "$GUARDED_UPDATE" rehearse 2>&1)"; then
        echo "rehearse did not refuse" >&2
        return 1
    fi
    grep -qF -- "$2" <<<"$out" ||
        {
            printf 'missing diagnostic: %s\n%s\n' "$2" "$out" >&2
            return 1
        }
    test "$(state_digest "$FX_STATE")" = "$before" &&
        ! test -e "$FX_STATE/ignored-snapshot-ready" ||
        {
            echo "the refused rehearse changed the guarded state" >&2
            return 1
        }
    if ls -d "$tmp"/copier-* >/dev/null 2>&1; then
        echo "the refused rehearse created a copier temp directory" >&2
        return 1
    fi
}
FX_UNCONVERGED='discover has not converged; rerun assets/guarded-update.sh discover'
# Condition 1, with no sentinel left: discover refuses on a capability conflict.
yq -i '.new_flag = false | .use_codex_cloud_review = true' "$FX_STATE/reviewed-data.yml"
expect_fail_contains "discover refuses a cloud review answer without Codex review" \
    'use_codex_cloud_review requires use_codex_review' \
    fx_run "$GUARDED_UPDATE" discover
expect_fail "the unconverged case carries no sentinel for the second condition" \
    grep -qF __REVIEW_REQUIRED__ "$FX_STATE/reviewed-data.yml"
expect_ok "rehearse refuses before any write when discover did not converge" \
    fx_rehearse_refused unconverged "$FX_UNCONVERGED"
# Converge discover again and decline NOTES.md, then copy the target for the
# two refusal cases before the main run writes ignored-snapshot-ready.
yq -i 'del(.use_codex_cloud_review)' "$FX_STATE/reviewed-data.yml"
expect_ok "discover converges again before the rehearsal" \
    fx_run "$GUARDED_UPDATE" discover
# Condition 1 again: a converged discover whose recorded render is gone.
FX_RENDER="$(cat "$FX_STATE/target-discovery-path")"
mv "$FX_RENDER" "$FX_RENDER.aside"
expect_ok "rehearse refuses before any write when the converged render is gone" \
    fx_rehearse_refused render-gone "$FX_UNCONVERGED"
mv "$FX_RENDER.aside" "$FX_RENDER"
# Condition 2: a sentinel written back after a converged discover.
FX_REVIEWED_OID="$(git hash-object "$FX_STATE/reviewed-data.yml")"
cp "$FX_STATE/reviewed-data.yml" "$FX/reviewed-data.converged"
yq -i '.new_flag = "__REVIEW_REQUIRED__"' "$FX_STATE/reviewed-data.yml"
expect_ok "rehearse refuses before any write while a sentinel stands" \
    fx_rehearse_refused sentinel 'still holds __REVIEW_REQUIRED__ values'
cp "$FX/reviewed-data.converged" "$FX_STATE/reviewed-data.yml"
expect_ok "the converged reviewed data is restored byte for byte" \
    test "$(git hash-object "$FX_STATE/reviewed-data.yml")" = "$FX_REVIEWED_OID"
git -C "$FX_TARGET" rm -q NOTES.md
git_commit_all "$FX_TARGET" "decline the notes"
for fx_case in scratch-fails migrations; do
    cp -a "$FX_TARGET" "$FX/case-$fx_case"
    mkdir "$FX/case-$fx_case.tmp"
done
expect_ok "rehearse classifies the scratch apply over converged guarded state" \
    fx_run "$GUARDED_UPDATE" rehearse
expect_ok "rehearse writes the path lists, backup and its object IDs, and ready" \
    sh -c 'cd "$1" && for f in baseline-managed-paths managed-paths \
            ignored-managed-paths ignored-existing-paths ignored-absent-paths \
            apply-before-paths apply-after-paths nonadoption-candidates; do
            test -f "$f" || { echo "missing $f" >&2; exit 1; }
        done
        test "$(cat ignored-snapshot-ready)" = ready &&
        test "$(cat ignored-backup-oid)" = "$(git hash-object ignored-backup.tar)" &&
        test "$(cat ignored-managed-paths-oid)" = \
            "$(git hash-object ignored-managed-paths)"' sh \
    "$FX_STATE"
expect_ok "rehearse reports the declined path in the five report columns" \
    test "$(cat "$FX_STATE/nonadoption-report.tsv")" = \
    "$(printf 'NOTES.md\tnonadopt-both\tno\tbaseline+target\t-')"
expect_ok "rehearse leaves the real worktree clean" \
    test -z "$(git -C "$FX_TARGET" status --porcelain)"
FX_REHEARSED="$(state_digest "$FX_STATE")"
fx_rehearse_silently() {
    local out
    out="$(fx_run "$GUARDED_UPDATE" rehearse 2>&1)" && test -z "$out"
}
expect_ok "a rehearse rerun over ignored-snapshot-ready skips the rehearsal" \
    fx_rehearse_silently
expect_ok "the skipped rehearse rerun changed no state file" \
    test "$(state_digest "$FX_STATE")" = "$FX_REHEARSED"
# A directory where the render ships a file: Copier refuses it in the scratch,
# so the run stops, keeps the scratch and names it, and freezes nothing.
FX_CASE="$FX/case-scratch-fails"
git -C "$FX_CASE" rm -q README.md
mkdir "$FX_CASE/README.md"
printf '%s\n' 'not the readme' >"$FX_CASE/README.md/NOTICE.txt"
git_commit_all "$FX_CASE" "a directory where a file belongs"
expect_fail_contains "a failed scratch apply names the scratch it left behind" \
    "scratch apply failed; the guarded update would fail the same way — inspect $(cd "$FX_CASE.tmp" && pwd -P)/copier-nonadoption-apply-" \
    fx_run_in "$FX_CASE" "$FX_CASE.tmp" "$GUARDED_UPDATE" rehearse
expect_ok "the failed rehearsal kept its scratch and wrote no ready marker" \
    sh -c 'ls -d "$1"/copier-nonadoption-apply-* >/dev/null &&
        ! test -e "$2/.copier-guarded-update/ignored-snapshot-ready"' sh \
    "$FX_CASE.tmp" "$FX_CASE"
# A target that declares _migrations is not rehearsed. prepare froze the guarded
# snapshot before this commit existed, so the case's state points at one that
# has it.
FX_CASE="$FX/case-migrations"
git -C "$FX_ORIGIN" switch -q -c fixture-migrations
cat >>"$FX_ORIGIN/copier.yml" <<'EOF'
_migrations:
  - command: ["sh", "-c", "echo ran >> migration-sentinel.txt"]
EOF
git_commit_all "$FX_ORIGIN" "the target declares a migration"
git clone -q --no-checkout "$FX_ORIGIN" "$FX_CASE.template"
git -C "$FX_ORIGIN" rev-parse HEAD >"$FX_CASE/.copier-guarded-update/target-commit"
printf '%s\n' "$FX_CASE.template" >"$FX_CASE/.copier-guarded-update/template-path"
git -C "$FX_ORIGIN" switch -q main
fx_rehearse_logged() { # fx_rehearse_logged <case>: output kept in <case>.log
    fx_run_in "$1" "$1.tmp" "$GUARDED_UPDATE" rehearse >"$1.log" 2>&1
}
expect_ok "rehearse completes without rehearsing a target that declares _migrations" \
    fx_rehearse_logged "$FX_CASE"
expect_ok "rehearse says why it refused the rehearsal" \
    grep -qF "target declares 1 _migrations; skipping the rehearsal" "$FX_CASE.log"
expect_ok "the refused rehearsal still classifies, as unknown-until-apply" \
    grep -qxF "$(printf 'NOTES.md\tunknown-until-apply\tno\tbaseline+target\t-')" \
    "$FX_CASE/.copier-guarded-update/nonadoption-report.tsv"
expect_ok "the refused rehearsal ran no migration and made no scratch" \
    sh -c '! test -e "$1/migration-sentinel.txt" &&
        ! ls -d "$2"/copier-nonadoption-apply-* >/dev/null 2>&1 &&
        test "$(cat "$1/.copier-guarded-update/ignored-snapshot-ready")" = ready' sh \
    "$FX_CASE" "$FX_CASE.tmp"

# ── present and apply, on the same fixture (#2043) ────────────────────
# A logging copier stub sits first on PATH for every present/apply run, so a
# refusal is proved to come before Copier starts rather than inferred from its
# message. It runs the real copier unless COPIER_STUB_FAIL is set, which stands
# in for a Copier run that dies part-way.
FX_STUB="$FX/copier-stub"
mkdir -p "$FX_STUB"
FX_REAL_COPIER="$(command -v copier)"
cat >"$FX_STUB/copier" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$COPIER_STUB_LOG"
[ -z "\${COPIER_STUB_FAIL:-}" ] || exit 3
exec "$FX_REAL_COPIER" "\$@"
EOF
chmod +x "$FX_STUB/copier"
# confirm-answers.sh refuses a group- or world-writable state directory, and
# prepare's mkdir follows the ambient umask; hold the fixture to a private one
# whatever umask this test runs under. The copies below keep the mode.
chmod go-w "$FX_STATE"
mkdir "$FX_TARGET.tmp"
fx_guarded() { # fx_guarded <repository> <guarded-update args...>: stubbed, logged
    local dir="$1"
    shift
    fx_run_in "$dir" "$dir.tmp" env PATH="$FX_STUB:$PATH" \
        COPIER_STUB_LOG="$dir.copier-log" "$GUARDED_UPDATE" "$@"
}
fx_refused() { # fx_refused <repository> <message> <guarded-update args...>
    local dir="$1" message="$2" before out
    shift 2
    before="$(state_digest "$dir/.copier-guarded-update")" || return 1
    if out="$(fx_guarded "$dir" "$@" 2>&1)"; then
        echo "$* did not refuse" >&2
        return 1
    fi
    grep -qF -- "$message" <<<"$out" ||
        {
            printf 'missing diagnostic: %s\n%s\n' "$message" "$out" >&2
            return 1
        }
    test "$(state_digest "$dir/.copier-guarded-update")" = "$before" ||
        {
            echo "the refused $* changed the guarded state" >&2
            return 1
        }
    ! test -s "$dir.copier-log" ||
        {
            echo "the refused $* started Copier: $(cat "$dir.copier-log")" >&2
            return 1
        }
}
fx_case() { # fx_case <name>: a copy of the rehearsed target back at its prepared HEAD
    local dir="$FX/case-$1"
    cp -a "$FX_TARGET" "$dir" && mkdir "$dir.tmp" &&
        git -C "$dir" reset -q --hard "$(cat "$dir/.copier-guarded-update/start-head")"
}
# present's entry guard, the same as rehearse's, refuses before any write.
fx_case present-guard
FX_CASE="$FX/case-present-guard"
rm "$FX_CASE/.copier-guarded-update/target-discovery-path"
expect_ok "present refuses before any write when discover did not converge" \
    fx_refused "$FX_CASE" \
    'discover has not converged; rerun assets/guarded-update.sh discover until it does, then present' \
    present
cp "$FX_STATE/target-discovery-path" "$FX_CASE/.copier-guarded-update/"
yq -i '.new_flag = "__REVIEW_REQUIRED__"' "$FX_CASE/.copier-guarded-update/reviewed-data.yml"
expect_ok "present refuses before any write while a sentinel stands" \
    fx_refused "$FX_CASE" 'still holds __REVIEW_REQUIRED__ values; review them and rerun discover before present' \
    present
expect_fail "present refused while the reviewed data was never frozen" \
    test -e "$FX_CASE/.copier-guarded-update/reviewed-data-oid"
expect_fail_contains "present takes no argument but --confirm" \
    'usage: guarded-update.sh' fx_guarded "$FX_TARGET" present --yes
expect_fail_contains "apply takes no argument but --pretend" \
    'usage: guarded-update.sh' fx_guarded "$FX_TARGET" apply --confirm
# present itself: the table, the freeze, and no confirmation.
fx_present_logged() { fx_guarded "$FX_TARGET" present >"$FX/present.out" 2>&1; }
expect_ok "present prints the confirmation table over converged state" \
    fx_present_logged
expect_ok "present freezes the reviewed data and extracts the target copier.yml" \
    sh -c 'test "$(cat "$1/reviewed-data-oid")" = "$(git hash-object "$1/reviewed-data.yml")" &&
        test "$(git -C "$2" show "$3":copier.yml | git hash-object --stdin)" = \
            "$(git hash-object "$1/target-copier.yml")"' sh \
    "$FX_STATE" "$FX_ORIGIN" "$FX_TARGET_COMMIT"
expect_ok "present lists every active question in its table" \
    sh -c 'while IFS= read -r key; do
        grep -qF -- "$key" "$1" || { echo "missing $key" >&2; exit 1; }
    done <"$2"' sh "$FX/present.out" "$FX_STATE/active-target-questions"
expect_fail "present without --confirm records no confirmation marker" \
    test -e "$FX_STATE/answers-confirmed"
expect_fail "present starts no Copier process" test -s "$FX_TARGET.copier-log"
# challenge-r1-codex-adversarial-1, restructured in round 2 (-1/-2): ONE
# mode-independent checkpoint note on every confirm-answers.sh path names each
# mode's trusted run (guarded-update.sh apply for update, copier copy --trust for
# adopt-existing and new-repo), the standing-grant warning and the never-self-
# grant rule, and SKILL.md and copier-gotchas.md section 10 say the same. It is
# checked on present's single call and on the fleet parent's --batch path.
cat >"$FX/batch.json" <<'EOF'
[{"repository": "fixture/target",
  "template_copier": "target/.copier-guarded-update/target-copier.yml",
  "data_file": "target/.copier-guarded-update/reviewed-data.yml",
  "recorded": "target/.copier-guarded-update/original-answers.yml",
  "active_keys": "target/.copier-guarded-update/active-target-questions",
  "template_commit": "fixture-commit",
  "state_dir": "target/.copier-guarded-update"}]
EOF
fx_phrases() { # fx_phrases <file> <phrase>...: each phrase, whitespace-folded
    local file="$1" flat phrase
    shift
    flat="$(tr -s ' \n' '  ' <"$file")"
    for phrase in "$@"; do
        grep -qF -- "$phrase" <<<"$flat" || {
            printf 'missing from %s: %s\n' "$file" "$phrase" >&2
            return 1
        }
    done
}
fx_checkpoint_note() {
    local out update_run copy_run grant
    update_run='In update mode it is `guarded-update.sh apply`'
    copy_run='In adopt-existing and new-repo it is `copier copy --trust`'
    grant='An allowlist such as `Bash(copier copy:*)`, or one covering `guarded-update.sh apply`, is a standing grant that authorizes every later trusted run'
    "$STANDARDIZE_ASSETS/confirm-answers.sh" --batch "$FX/batch.json" \
        >"$FX/batch.out" 2>&1 || return 1
    for out in "$FX/present.out" "$FX/batch.out"; do
        fx_phrases "$out" "$update_run" "$copy_run" "$grant" 'Agents never self-grant it' &&
            [ "$(grep -c 'The next step executes the template' "$out")" -eq 1 ] || return 1
    done
    fx_phrases "$repo/ai/skills/repo/standardize-repo/SKILL.md" \
        "$update_run" "$copy_run" 'or one covering `guarded-update.sh apply`, is a standing grant' &&
        fx_phrases "$STANDARDIZE_REFS/copier-gotchas.md" \
            "$update_run" "$copy_run" 'or one covering `guarded-update.sh apply`, is a standing grant' &&
        fx_phrases "$STANDARDIZE_REFS/mode-update-preflight.md" \
            'the trusted run the human approves at the prompt is `assets/guarded-update.sh apply`' &&
        fx_phrases "$STANDARDIZE_REFS/mode-update.md" \
            'the trusted run the human approves is `guarded-update.sh apply`' || return 1
    # challenge-r3-codex-adversarial-1: the update-mode references may mention a
    # copier update rule only to say it does not cover the apply.
    local doc flat
    for doc in "$STANDARDIZE_REFS/mode-update-preflight.md" "$STANDARDIZE_REFS/mode-update.md"; do
        flat="$(tr -s ' \n' '  ' <"$doc")"
        [ "$(grep -oF -- '`Bash(copier update:*)`' <<<"$flat" | wc -l)" -eq \
            "$(grep -oF -- '`Bash(copier update:*)` rule does not cover it' <<<"$flat" | wc -l)" ] || {
            echo "$doc presents a Bash(copier update:*) rule as the update-mode checkpoint" >&2
            return 1
        }
    done
}
expect_ok "the checkpoint note names each mode's trusted run and both warnings, single and --batch" \
    fx_checkpoint_note
FX_PRESENTED_OID="$(git hash-object "$FX_STATE/reviewed-data.yml")"
cp "$FX_STATE/reviewed-data.yml" "$FX/reviewed-data.presented"
printf '%s\n' '# edited after the preview' >>"$FX_STATE/reviewed-data.yml"
expect_ok "present refuses reviewed data changed after the freeze" \
    fx_refused "$FX_TARGET" 'reviewed data changed after preview' present
# challenge-r1-codex-adversarial-2: restore from the saved copy; BSD sed reads
# `-i '$d'` as a backup suffix and aborts the suite under set -e.
cp "$FX/reviewed-data.presented" "$FX_STATE/reviewed-data.yml"
expect_ok "the frozen reviewed data is restored byte for byte" \
    test "$(git hash-object "$FX_STATE/reviewed-data.yml")" = "$FX_PRESENTED_OID"
# apply: refusals before Copier, the confirmed preview and apply, and recovery.
for fx_name in apply apply-head apply-oid apply-fails; do fx_case "$fx_name"; done
FX_CASE="$FX/case-apply"
FX_UNCONFIRMED='resolved answers were never confirmed; do not run Copier'
expect_ok "an unconfirmed apply is refused before Copier runs" \
    fx_refused "$FX_CASE" "$FX_UNCONFIRMED" apply
expect_ok "an unconfirmed preview is refused before Copier runs" \
    fx_refused "$FX_CASE" "$FX_UNCONFIRMED" apply --pretend
expect_fail "the refused apply wrote no apply phase" \
    test -e "$FX_CASE/.copier-guarded-update/apply-phase"
fx_confirm() { # fx_confirm <repository>: the operator's explicit confirmation
    fx_guarded "$1" present --confirm >/dev/null &&
        test -f "$1/.copier-guarded-update/answers-confirmed"
}
for fx_name in apply apply-head apply-oid apply-fails; do
    expect_ok "present --confirm records the confirmation ($fx_name)" \
        fx_confirm "$FX/case-$fx_name"
done
git -C "$FX/case-apply-head" -c user.email=test@example.com -c user.name=test \
    -c commit.gpgsign=false commit -q --allow-empty -m "an intervening commit"
printf '%s\n' '# edited after confirmation' \
    >>"$FX/case-apply-oid/.copier-guarded-update/reviewed-data.yml"
FX_BINDING='working checkout no longer matches guarded update state'
for fx_name in apply-head apply-oid; do
    expect_ok "apply refuses a binding mismatch before Copier ($fx_name)" \
        fx_refused "$FX/case-$fx_name" "$FX_BINDING" apply
done
expect_ok "the confirmed preview runs the guarded copier --pretend" \
    fx_guarded "$FX_CASE" apply --pretend
expect_ok "the preview changes nothing in the worktree" \
    test -z "$(git -C "$FX_CASE" status --porcelain)"
expect_ok "the confirmed apply runs Copier and records applied" \
    fx_guarded "$FX_CASE" apply
expect_ok "the apply phase reads applied after a normal return" \
    grep -qxF applied "$FX_CASE/.copier-guarded-update/apply-phase"
# Copier records the target's describe form; promote (#2044) later writes the
# full hash. The new question's reviewed answer is what proves the target landed.
expect_ok "the apply recorded the target's new question with its reviewed answer" \
    sh -c 'test "$(yq -r .new_flag "$1")" = false &&
        test "$(yq -r ._commit "$1")" != "$2"' sh \
    "$FX_CASE/.copier-answers.yml" "$FX_BASELINE"
expect_ok "the preview and the apply each ran Copier once, with one argument set" \
    test "$(cat "$FX_CASE.copier-log")" = "$(printf '%s\n' \
        "update --trust --defaults --pretend --vcs-ref=$FX_TARGET_COMMIT --data-file=.copier-guarded-update/reviewed-data.yml" \
        "update --trust --defaults --vcs-ref=$FX_TARGET_COMMIT --data-file=.copier-guarded-update/reviewed-data.yml")"
: >"$FX_CASE.copier-log"
# Back to the prepared tree, so every binding holds and only the phase refuses.
git -C "$FX_CASE" reset -q --hard
git -C "$FX_CASE" clean -qfd
expect_ok "apply over a state whose apply already started is refused before Copier" \
    fx_refused "$FX_CASE" 'apply already started; do not rerun Copier' apply
FX_CASE="$FX/case-apply-fails"
fx_apply_dies() {
    ! COPIER_STUB_FAIL=1 fx_guarded "$FX_CASE" apply >"$FX_CASE.out" 2>&1
}
expect_ok "an interrupted Copier run fails the apply" fx_apply_dies
expect_ok "the interrupted apply leaves the applying phase in place" \
    sh -c 'grep -qxF applying "$1/.copier-guarded-update/apply-phase" &&
        grep -qF "preserve the applying phase and recovery state" "$1.out" &&
        test "$(wc -l <"$1.copier-log")" -eq 1' sh "$FX_CASE"
: >"$FX_CASE.copier-log"
expect_ok "a rerun after the interruption refuses before Copier" \
    fx_refused "$FX_CASE" 'apply already started; do not rerun Copier' apply

# ── the present and apply assertions, moved from scripts/test-skills.sh (#2043) ──
# Moved with the code they cover, names and inventory tags unchanged. Two apply
# rows check promote code and six the orphan sweep (#2044 owns both); they read
# the assembled procedure, so they hold wherever that code lives.
# It reads YAML and hashes files; copier is never a command it runs, which is
# what makes it safe to call before the trusted execution it gates.
expect_ok "the confirmation asset never invokes copier as a command" \
    sh -c '! grep -Eq "^[[:space:]]*(sudo[[:space:]]+)?copier[[:space:]]" "$1/confirm-answers.sh"' \
    sh "$STANDARDIZE_ASSETS"
expect_ok "mode-update presents every active question, not the reviewed subset" \
    grep -qF -- '--active-keys "$GUARDED_STATE/active-target-questions"' \
    "$UPDATE_PROCEDURE"
expect_fail "mode-update never narrows the confirmation table to reviewed-keys" \
    grep -qF -- '--active-keys "$GUARDED_STATE/reviewed-keys"' \
    "$UPDATE_PROCEDURE"
expect_ok "every mode's --check binds the recorded answers too" \
    sh -c 'for d in "$2" "$1/mode-adopt-existing.md" "$1/mode-new-repo.md"; do
        awk "/assets\/confirm-answers.sh --check/ { inblock = 1; next }
             inblock && /--recorded/ { found++ }
             inblock && /--state-dir/ { inblock = 0 }
             END { exit found > 0 ? 0 : 1 }" "$d" || exit 1
    done' sh "$STANDARDIZE_REFS" "$UPDATE_PROCEDURE"
expect_ok "mode-update checks the confirmation before the --pretend rehearsal" \
    sh -c 'awk "/assets\/confirm-answers.sh --check/ { seen = 1 } /run_guarded_copier update --trust --defaults --pretend/ { exit seen ? 0 : 1 }" "$1"' \
    sh "$UPDATE_PROCEDURE"
expect_ok "update guidance binds apply and promotion to the prepared checkout" \
    test "$(grep -Fc 'working checkout no longer matches guarded update state' \
        "$UPDATE_PROCEDURE")" -eq 2
expect_ok "update guidance validates every reviewed key after apply" \
    grep -qF 'done <"$GUARDED_STATE/reviewed-keys"' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance proves Copier applied the target before promotion" \
    grep -qF 'guarded update did not apply the validated target' \
    "$UPDATE_PROCEDURE"
expect_ok "update guidance writes apply intent before Copier can mutate the tree" \
    sh -c 'phase_line="$(grep -nF "write_guarded_phase applying" "$1" |
            cut -d: -f1)"
        copier_line="$(grep -nF \
            "if run_guarded_copier update --trust --defaults" "$1" |
            cut -d: -f1)"
        test "$phase_line" -lt "$copier_line" &&
        grep -qF "An \`applying\`" "$1" &&
        grep -qF "state is never promotable" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Rewritten (#2043): over the assembled procedure the second clean-worktree
# test had become rehearse's, inside the asset, so the old `sed -n 2p` ordering
# proved nothing about apply. It now reads the apply function itself, where the
# check must occur exactly once and before the applying phase is written.
GU_APPLY_FN="$TMPROOT/guarded-update-apply.sh"
sed -n '/^guarded_update_apply() {$/,/^}$/p' "$GUARDED_UPDATE" >"$GU_APPLY_FN"
expect_ok "update guidance requires a clean worktree immediately before apply" \
    sh -c 'test "$(grep -cF "test -z \"\$(git status --porcelain)\"" "$1")" -eq 1 &&
        clean_line="$(grep -nF "test -z \"\$(git status --porcelain)\"" "$1" |
            cut -d: -f1)" &&
        phase_line="$(grep -nF "write_guarded_phase applying" "$1" |
            cut -d: -f1)" &&
        test -n "$phase_line" && test "$clean_line" -lt "$phase_line"' sh \
    "$GU_APPLY_FN"
expect_ok "orphan sweep compares the repo against a rendered target inventory" \
    sh -c 'grep -qF "failed to render the target inventory" "$1" &&
        grep -qF "git ls-files '\''scripts/*'\'' |" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "orphan sweep counts only scripts surviving in the worktree" \
    sh -c 'grep -qF "test -e \"\$SCRIPT_PATH\" || test -L \"\$SCRIPT_PATH\"" "$1" &&
        grep -qF "reads the **index**" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "orphan sweep renders from the frozen guarded source" \
    sh -c 'end="$(grep -nF "failed to render the target inventory" "$1" |
            cut -d: -f1)"
        test -n "$end" || exit 1
        block="$(sed -n "$((end - 6)),${end}p" "$1")"
        # shell-robustness: begin-exempt — the pipeline is quoted text passed to another shell, not code this shell runs
        printf "%s\n" "$block" |
            grep -F >/dev/null "run_guarded_copier copy --trust --defaults --skip-tasks" &&
        printf "%s\n" "$block" |
            grep -F >/dev/null -- "--vcs-ref=\"\$HARMON_INIT_COMMIT\"" &&
        printf "%s\n" "$block" |
            grep -F >/dev/null "\"\$HARMON_INIT_SOURCE\" \"\$RENDERED_TREE\""' sh \
    "$UPDATE_PROCEDURE"
# shell-robustness: end-exempt
expect_fail "orphan sweep never renders from a mutable checkout or tag" \
    grep -qF 'copier copy --trust --defaults --skip-tasks --vcs-ref=<new>' \
    "$UPDATE_PROCEDURE"
expect_fail "orphan sweep never strips template/ off a raw tree listing" \
    grep -qF "sed 's|^template/||'" \
    "$UPDATE_PROCEDURE"
expect_fail "orphan sweep does not ask the reader to un-gate raw names by hand" \
    grep -qF 'jinja-wrapped in the raw listing' \
    "$UPDATE_PROCEDURE"

# ── the rehearsal's assertions, moved from scripts/test-skills.sh (#2042) ──
# Moved unchanged with the code they cover, in their original order; like the
# prepare/discover assertions above, they read the whole procedure, with the
# asset in the place its steps ran.
# Rehearsal, preview and apply must all be handed the SAME frozen payload — a
# rehearsal run with different answers predicts a different update. Since
# #2043 all three sites are in the asset, and none is left in the Markdown.
expect_ok "update guidance passes one frozen reviewed-data file to rehearsal, preview and apply" \
    sh -c 'test "$(grep -Fc -- "--data-file=\"\$REVIEWED_DATA\"" "$1")" -eq 3 &&
        test "$(grep -Fc -- "--data-file=\"\$REVIEWED_DATA\"" "$2")" -eq 3' sh \
    "$GUARDED_UPDATE" "$UPDATE_PROCEDURE"
# The §1 non-adoption classifier is lifted out of the asset (it sits in the
# assembled procedure, #2042) and RUN against the
# guarded-update fixture far below, so the marker pair has to stay unique: a
# second copy of either marker would make the sed range swallow whatever sits
# between them and hand `bash -eu` a truncated program.
GU_NONADOPT_SNIPPET="$TMPROOT/nonadoption-classify.sh"
sed -n '/# >>> nonadoption-classify >>>/,/# <<< nonadoption-classify <<</p' \
    "$UPDATE_PROCEDURE" >"$GU_NONADOPT_SNIPPET"
expect_ok "non-adoption snippet carries exactly one extraction marker pair" \
    sh -c 'test "$(grep -cF "# >>> nonadoption-classify >>>" "$1")" -eq 1 &&
        test "$(grep -cF "# <<< nonadoption-classify <<<" "$1")" -eq 1' sh \
    "$UPDATE_PROCEDURE"
# The same count invariant as the file-wide one above, scoped to the extracted
# snippet — it reads two `LC_ALL=C sort -u` inventories, so an unpinned `comm`
# rejects its own input under an ambient UTF-8 locale. Counting rather than
# asserting three literals keeps this true as sites are added.
expect_ok "non-adoption snippet pins collation on every comm invocation" \
    sh -c 'total="$(grep -cE "comm -[0-9]" "$1")"
        pinned="$(grep -cE "LC_ALL=C comm -[0-9]" "$1")"
        test "$total" -gt 0 && test "$total" -eq "$pinned"' sh \
    "$GU_NONADOPT_SNIPPET"
# `changed_in_range` on its own, against modes this suite can actually create.
# The probe used `test -x`, which answers "may THIS process execute this file
# HERE" — a fact about the mount and the caller, not about the render. A noexec
# mount cannot be arranged in a test, but the same discrimination shows in a
# mode whose exec bits are set for somebody other than the owner: `test -x` is
# false on both sides while the STORED bits differ, which is precisely the shape
# that used to report `no` for a real mode-only change.
GU_CIR="$TMPROOT/nonadoption-changed-in-range.sh"
{
    printf '%s\n' 'set -eu'
    sed -n '/^        nonadoption_stored_mode() {/,/^        }$/p' "$GU_NONADOPT_SNIPPET"
    sed -n '/^        nonadoption_changed_in_range() {/,/^        }$/p' "$GU_NONADOPT_SNIPPET"
    printf '%s\n' 'nonadoption_changed_in_range "$1"'
} >"$GU_CIR"
expect_ok "the changed_in_range probe is extractable from the snippet" \
    sh -c 'grep -qF "nonadoption_stored_mode() {" "$1" &&
        grep -qF "nonadoption_changed_in_range() {" "$1"' sh "$GU_CIR"
# The stance itself, so a later edit cannot quietly reintroduce the effective
# test: the probe must read stored bits and never ask about executability here.
expect_ok "the changed_in_range probe reads stored bits, not effective access" \
    sh -c 'grep -qF "ls -ld --" "$1" &&
        ! grep -qE "test !? ?-x \"\\\$NONADOPT_(BASE|TGT)\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
GU_CIR_BASE="$TMPROOT/changed-in-range/baseline"
GU_CIR_TGT="$TMPROOT/changed-in-range/target"
mkdir -p "$GU_CIR_BASE" "$GU_CIR_TGT"
gu_cir() {
    BASELINE_DISCOVERY="$GU_CIR_BASE" TARGET_DISCOVERY="$GU_CIR_TGT" \
        bash -eu "$GU_CIR" "$1"
}
printf 'same\n' >"$GU_CIR_BASE/same.md"
printf 'same\n' >"$GU_CIR_TGT/same.md"
if [ "$(gu_cir same.md)" = no ]; then
    ok "changed_in_range reports no for an unchanged file"
else
    bad "changed_in_range reports no for an unchanged file"
fi
printf 'baseline\n' >"$GU_CIR_BASE/content.md"
printf 'target\n' >"$GU_CIR_TGT/content.md"
if [ "$(gu_cir content.md)" = yes ]; then
    ok "changed_in_range reports yes for a content change"
else
    bad "changed_in_range reports yes for a content change"
fi
printf 'script\n' >"$GU_CIR_BASE/hook.sh"
printf 'script\n' >"$GU_CIR_TGT/hook.sh"
chmod 644 "$GU_CIR_BASE/hook.sh"
chmod 755 "$GU_CIR_TGT/hook.sh"
if [ "$(gu_cir hook.sh)" = yes ]; then
    ok "changed_in_range reports yes for an ordinary exec-bit change"
else
    bad "changed_in_range reports yes for an ordinary exec-bit change"
fi
# The discrimination case: identical bytes, different STORED bits, and `test -x`
# false on both sides because the owner holds no exec bit either way.
printf 'shared\n' >"$GU_CIR_BASE/other-exec.md"
printf 'shared\n' >"$GU_CIR_TGT/other-exec.md"
chmod 644 "$GU_CIR_BASE/other-exec.md"
chmod 645 "$GU_CIR_TGT/other-exec.md"
# Root is the exception and has to be named rather than tripped over: UID 0
# passes an execute check whenever ANY execute bit is set, so `test -x` reads
# true for the 0645 side and the premise below cannot hold. The stored-mode
# comparison is unaffected — that is the whole point of it — so the fixture
# records why the discrimination is unobservable instead of failing the suite
# for a container that happens to run as root.
if [ "$(id -u)" -eq 0 ]; then
    ok "the changed_in_range mode fixture skips its effective-access premise as root"
elif [ -x "$GU_CIR_BASE/other-exec.md" ] || [ -x "$GU_CIR_TGT/other-exec.md" ]; then
    bad "the changed_in_range mode fixture keeps effective executability equal"
else
    ok "the changed_in_range mode fixture keeps effective executability equal"
fi
if [ "$(gu_cir other-exec.md)" = yes ]; then
    ok "changed_in_range sees a mode change effective executability hides"
else
    bad "changed_in_range sees a mode change effective executability hides"
fi
if [ "$(gu_cir absent.md)" = unknown ]; then
    ok "changed_in_range reports unknown for a path it cannot read"
else
    bad "changed_in_range reports unknown for a path it cannot read"
fi
# §2 promotion deletes $GUARDED_STATE outright, and both §4 and §5 still need
# the report, so it has to be copied somewhere that survives — the git dir,
# same idiom as the deferred-findings notes, BRANCH KEY included. An ordinary
# clone switches branches in place, so one shared file means branch B's update
# overwrites branch A's only copy before A's PR body was ever written.
expect_ok "update guidance persists the non-adoption report past guarded teardown" \
    sh -c 'grep -qF "cp \"\$GUARDED_STATE/nonadoption-report.tsv\"" "$1" &&
        grep -qF -- "--git-path \"guarded-update-nonadoption/\$GUARDED_NONADOPT_BRANCH\"" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "the non-adoption report is keyed by branch on every path that touches it" \
    sh -c 'test "$(grep -cF -- "guarded-update-nonadoption/\$(git branch --show-current)" \
            "$1")" -eq 2 &&
        ! grep -qE -- "--git-path guarded-update-nonadoption[\"[:space:]]*$" "$1" &&
        grep -qF "detached HEAD" "$1" &&
        grep -qF "mkdir -p \"\$(dirname \"\$GUARDED_NONADOPT_FILE\")\"" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Branch-keying without an orphan sweep just moves the loss: a branch renamed
# mid-update strands its report under the old name, where nothing looks again.
# §2 writes TWO branch-keyed files, so hand-off must sweep and retire both.
# Deleting the report and leaving the verdict left a clean verdict in the git
# directory forever with nothing to describe — the stale-verdict shape §1's entry
# clearing exists to prevent, reintroduced at the very end.
expect_ok "hand-off sweeps both branch-keyed trees for orphans before deleting" \
    sh -c 'grep -qF "ls -R \"\$(git rev-parse --git-path guarded-update-nonadoption)\"" "$1" &&
        grep -qF "ls -R \"\$(git rev-parse --git-path guarded-update-reconciled)\"" "$1" &&
        grep -qF "Sweep BOTH trees for orphans" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "hand-off retires both branch-keyed files together" \
    sh -c 'grep -qF "HANDOFF_VERDICT" "$1" && grep -qF "HANDOFF_REPORT" "$1" &&
        grep -qF "never the directories" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The ORDER is the fix. A clean verdict with no report beside it is the one
# combination that lies, so the verdict goes first and a failure there stops
# before the report is touched. Asserted on line numbers, because a comment
# saying "verdict first" over a loop that does the opposite would still pass.
expect_ok "hand-off retires the verdict before the report" \
    sh -c 'v="$(grep -nF "rm -f -- \"\$HANDOFF_VERDICT\"" "$1" | cut -d: -f1)"
        r="$(grep -nF "rm -f -- \"\$HANDOFF_REPORT\"" "$1" | cut -d: -f1)"
        test -n "$v" && test -n "$r" && test "$v" -lt "$r" &&
        grep -qF "the report is untouched at" "$1" &&
        grep -qF "either both files still exist or the verdict is already gone" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The schema overview is what a reader meets first; it has to name the labels the
# classifier actually emits, not the ones three redesigns ago.
expect_ok "the schema overview names the classes and notes in use" \
    sh -c 'over="$(grep -n "Silent non-adoption is the one gap" "$1" | cut -d: -f1)"
        seg="$(sed -n "${over},$((over + 22))p" "$1")"
        # shell-robustness: begin-exempt — the pipeline is quoted text passed to another shell, not code this shell runs
        printf "%s\n" "$seg" | grep -F >/dev/null "co-owned-prose" &&
        printf "%s\n" "$seg" | grep -F >/dev/null "known-false-verified" &&
        printf "%s\n" "$seg" | grep -F >/dev/null "unverified-equivalent" &&
        printf "%s\n" "$seg" | grep -F >/dev/null "gitkeep" &&
        printf "%s\n" "$seg" | grep -F >/dev/null "unknown-until-apply"' sh \
    "$UPDATE_PROCEDURE"
# shell-robustness: end-exempt
expect_fail "no pre-redesign class label survives in the guidance" \
    grep -qE "gitkeep-benign|filtered-known" "$UPDATE_PROCEDURE"
# Grepping the recipe proves it says the right words; running it proves the words
# work. The branch key is a PATH, and this repo's own branch names contain `/` —
# so `mkdir -p "$(dirname …)"` is load-bearing and no grep can show that it fires.
GU_NONADOPT_PERSIST="$TMPROOT/nonadoption-persist.sh"
awk '/^GUARDED_NONADOPT_BRANCH="\$\(git branch --show-current\)"$/ { inblk = 1 }
     inblk && /^```$/ { exit }
     inblk { print }' \
    "$UPDATE_PROCEDURE" >"$GU_NONADOPT_PERSIST"
# An extraction that silently found nothing would run an empty program and pass.
expect_ok "the non-adoption persistence recipe is extractable" \
    sh -c 'test -s "$1" && grep -qF "cp \"\$GUARDED_STATE" "$1"' sh \
    "$GU_NONADOPT_PERSIST"
GU_PERSIST_REPO="$TMPROOT/nonadoption-persist-repo"
git init -q "$GU_PERSIST_REPO" >/dev/null
git -C "$GU_PERSIST_REPO" config user.email test@example.com
git -C "$GU_PERSIST_REPO" config user.name "Test"
git -C "$GU_PERSIST_REPO" commit -q --allow-empty -m seed >/dev/null
# A slashed name, because that is the case `mkdir -p` exists for and the case a
# `/`-folding key would silently collide with `feat-343-report`.
git -C "$GU_PERSIST_REPO" switch -q -c feat/343-report >/dev/null
mkdir -p "$GU_PERSIST_REPO/.copier-guarded-update"
printf 'seeded\tnonadopt-both\tno\tbaseline+target\t-\n' \
    >"$GU_PERSIST_REPO/.copier-guarded-update/nonadoption-report.tsv"
# Persistence refuses an unreconciled report: §2 reconciles first, and a report
# published without that verdict would describe an unverified tree.
printf 'reconciled: clean\n' \
    >"$GU_PERSIST_REPO/.copier-guarded-update/nonadoption-reconciled"
expect_ok "the non-adoption persistence recipe runs clean under bash -eu" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update bash -eu "$2"' sh \
    "$GU_PERSIST_REPO" "$GU_NONADOPT_PERSIST"
expect_ok "the persisted report lands under the branch name verbatim" \
    grep -qxF "$(printf 'seeded\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_PERSIST_REPO/.git/guarded-update-nonadoption/feat/343-report"
# The whole point of the key: a second branch's run must not clobber the first.
git -C "$GU_PERSIST_REPO" switch -q -c feat/other >/dev/null
printf 'other\tnonadopt-both\tno\tbaseline+target\t-\n' \
    >"$GU_PERSIST_REPO/.copier-guarded-update/nonadoption-report.tsv"
expect_ok "a second branch's guarded run persists alongside the first" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update bash -eu "$2"' sh \
    "$GU_PERSIST_REPO" "$GU_NONADOPT_PERSIST"
expect_ok "the first branch's non-adoption report survives the second run" \
    grep -qF seeded \
    "$GU_PERSIST_REPO/.git/guarded-update-nonadoption/feat/343-report"
expect_ok "the second branch's report is written to its own key" \
    grep -qF other "$GU_PERSIST_REPO/.git/guarded-update-nonadoption/feat/other"
# Detached HEAD has no key at all, so the recipe stops rather than guessing one.
git -C "$GU_PERSIST_REPO" switch -q --detach HEAD >/dev/null
expect_fail "the persistence recipe refuses a detached HEAD" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update bash -eu "$2"' sh \
    "$GU_PERSIST_REPO" "$GU_NONADOPT_PERSIST"
expect_ok "update verification re-checks every non-adoption class after the merge" \
    sh -c 'grep -qF "CONFIRMED silent non-adoption" "$1" &&
        grep -qF "the real apply left it in place" "$1" &&
        grep -qF "the real apply did not" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The table is the whole deliverable: classification nobody reads changes
# nothing, so hand-off has to name the section, its columns, and the explicit
# wording for the empty case an omitted section is otherwise indistinguishable
# from.
expect_ok "update hand-off requires a silent non-adoption disposition table" \
    sh -c 'grep -qF "## Silent non-adoption" "$1" &&
        grep -qF "| Path |" "$1" &&
        grep -qF "| Disposition |" "$1" &&
        grep -qF "No unexplained silent" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The worked example is the part an operator actually copies, so a row that
# contradicts the contract above it is worse than no example. The contract says
# the table holds confirmed `nonadopt-both` only and that a `new-in-target`
# anomaly is called out separately; the example put a target-only CodeQL row
# straight into the table. It is the anomaly call-out now — and every remaining
# table row must be one the contract admits.
expect_ok "the hand-off example keeps apply anomalies out of the disposition table" \
    sh -c 'grep -qF "Files the update created — review what landed" "$1" &&
        ! grep -qE "^\| \`\.github/workflows/codeql\.yml\` \|" "$1" &&
        ! grep -qE "^\| \`\.github/CODEOWNERS\` \|" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The directory case aborts the rehearsal before any report exists, so the note
# it used to produce is unreachable. §5 must state the real contract instead of
# instructing a reviewer to disposition a row that can never appear.
expect_ok "the hand-off documents the directory abort, not a phantom note" \
    sh -c 'grep -qF "A directory where the render ships a file never reaches this report" "$1" &&
        test "$(grep -cF "repo-path-is-directory" "$1")" -eq 1' sh \
    "$UPDATE_PROCEDURE"
expect_ok "the hand-off contract carries the note vocabulary" \
    sh -c 'grep -qF "repo-ignored-only" "$1" &&
        grep -qF "unverified-equivalent" "$1" &&
        grep -qF "known-false-verified" "$1" &&
        grep -qF "co-owned-prose" "$1" &&
        grep -qF "twin-exists:" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The two axes, stated in the guidance itself: a class says what the apply does,
# a note says what was found out about it, and the note never removes the row.
expect_ok "update guidance separates transition class from explanation" \
    sh -c 'grep -qF "The classification is an observation, not a prediction" "$1" &&
        grep -qF "The evidence never removes the row" "$1" &&
        grep -qF "grouping, not filtering" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Explained absences are LISTED, one line each, not collapsed to counts — a count
# cannot be audited, which is how five rounds of review each found another
# transition hiding inside one.
expect_ok "explained absences are listed per path, never collapsed to a count" \
    sh -c 'grep -qF "### Explained absences" "$1" &&
        grep -qF "One line each, never a bare count" "$1" &&
        ! grep -qF "Filtered, not silent:" "$1"' sh \
    "$UPDATE_PROCEDURE"
# Only notes that record a DECISION route a row out of the table. `co-owned-prose`
# records none: co-ownership explains why a file the repo HAS differs, and an
# absent file differs from nothing — so an absent docs page is a permanent
# non-adoption exactly like an absent AGENTS.md, and owes a Why and a Disposition.
expect_ok "only decision-bearing notes route a row out of the disposition table" \
    sh -c 'grep -qF "Exactly three answer it" "$1" &&
        grep -qF "\`co-owned-prose\` is on that second list" "$1" &&
        grep -qF "and it is the one note that says" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "the worked example tables its co-owned absence" \
    sh -c 'grep -qE "^\| \`docs/runbooks/restore\.md\` \|.*co-owned-prose" "$1" &&
        ! grep -qE "^- \`docs/[^\`]*\` — co-owned-prose" "$1"' sh \
    "$UPDATE_PROCEDURE"
# One loop, four classes, no carve-outs — possible only because nothing is
# suppressed out of the report.
# The ordering is the fix: reconcile at the end of §2, before §3's prescribed
# edits, and have §4 read the frozen verdict rather than the tree.
expect_ok "reconciliation runs before the manual reconciliation section" \
    sh -c 'recon="$(grep -nF "nonadoption_reconcile ||" "$1" | cut -d: -f1)"
        s3="$(grep -nE "^## 3\. " "$1" | cut -d: -f1)"
        s4="$(grep -nE "^## 4\. " "$1" | cut -d: -f1)"
        test -n "$recon" && test "$recon" -lt "$s3" &&
        verdict="$(grep -nF "guarded-update-reconciled/" "$1" | head -1 | cut -d: -f1)"
        test "$verdict" -lt "$s3" &&
        later="$(grep -nF "the frozen reconciliation is not clean" "$1" | cut -d: -f1)"
        test "$later" -gt "$s4"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "section 4 verifies the frozen verdict instead of re-reading the tree" \
    sh -c 'grep -qF "Confirm the reconciliation was recorded" "$1" &&
        grep -qF "reconciled: clean" "$1" &&
        grep -qF "Do not re-derive it by re-reading the worktree" "$1" &&
        grep -qF "restored in §3: <reason>" "$1"' sh \
    "$UPDATE_PROCEDURE"
# `--skip-tasks` does not cover `_migrations`; copier runs them unguarded. A
# rehearsal would fire them a second time against a copy.
expect_ok "the rehearsal is refused when the target declares _migrations" \
    sh -c 'grep -qF "_migrations // [] | length" "$1" &&
        grep -qF "NONADOPT_REHEARSED" "$1" &&
        grep -qF "unknown-until-apply" "$1" &&
        grep -qF "migrations must run exactly once" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# Zero shared git metadata: a linked worktree's `.git` is a pointer file, and
# copier runs `git write-tree` in the subproject.
expect_ok "the rehearsal builds independent git metadata for the scratch" \
    sh -c 'grep -qF "git clone --no-hardlinks" "$1" &&
        grep -qF "rev-parse --absolute-git-dir" "$1" &&
        grep -qF "refusing to rehearse" "$1" &&
        ! grep -qF "cp -a . \"\$NONADOPT_SCRATCH/repo\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "the post-apply cross-check reconciles every class and fails closed" \
    sh -c 'grep -qF "RECONCILE_BAD" "$1" &&
        grep -qF "reconciliation failed on" "$1" &&
        grep -qF "the real apply created it" "$1" &&
        grep -qF "reconciled: clean" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The persistence write races the branch it is keyed by, so the binding is
# re-checked at the last moment and the write is atomic.
expect_ok "the non-adoption write re-checks its checkout binding and lands atomically" \
    sh -c 'grep -qF "refusing to write the non-adoption report" "$1" &&
        grep -qF "mv \"\$GUARDED_NONADOPT_FILE.\$\$.tmp\" \"\$GUARDED_NONADOPT_FILE\"" "$1" &&
        grep -qF "The binding is re-checked immediately before the write" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "copier gotchas own the permanent non-adoption reasoning" \
    sh -c 'grep -qE "^## 9\. " "$1" &&
        grep -qF "never adopts a file your baseline already shipped" "$1" &&
        grep -qF "permanent opt-out" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
# §9 used to say permanence covered files you "never had", full stop. It does
# not: a path the template gained AFTER the recorded baseline is target-only, and
# the update creates it — this suite's own end-to-end fixture asserts exactly
# that. The condition is BOTH renders, and the checklist bullet has to agree with
# the section it summarizes or the summary becomes the version people quote.
expect_ok "gotcha 9 scopes permanence to paths the baseline already shipped" \
    sh -c 'grep -qF "\"Both renders\" is the whole condition" "$1" &&
        grep -qF "is **target-only**" "$1" &&
        grep -qF "MISSING\` a file its baseline already shipped?" "$1" &&
        ! grep -qF "or never had" "$1" &&
        ! grep -qF "is opted out of paths it never saw" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
# The second carve-out, and the one that runs the other way: `_skip_if_exists`
# on an absent path RECREATES it. A permanence claim that omits this is not
# merely imprecise for CODEOWNERS, it is backwards.
# The Why must name copier's actual mechanism. "Presence in both renders means an
# empty diff" is wrong and predicts the wrong thing: it would have a changed-in-
# range deleted path conflict or come back, and it does neither.
expect_ok "gotcha 9 attributes permanence to copier's exclusion, not an empty diff" \
    sh -c 'grep -qF "not because the diff is empty" "$1" &&
        grep -qF "excludes them from creation" "$1" &&
        grep -qF "The exclusion is explicit, not emergent" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
# The quick checklist is the version people quote, so it has to name the same
# two carve-outs §9 does — and not name target-only, which is ordinary creation.
expect_ok "the gotcha checklist names both carve-outs and no phantom third" \
    sh -c 'grep -qF "Two carve-outs come" "$1" &&
        grep -qF "render'\''s own" "$1" &&
        grep -qF "is not a" "$1" &&
        ! grep -qF "Two exceptions, both" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
expect_ok "gotcha 9 carves out _skip_if_exists as a recreate, not a permanence" \
    sh -c 'grep -qF "There are TWO carve-outs" "$1" &&
        grep -qF "it renders the file fresh" "$1" &&
        grep -qF "never in that tree, can never show" "$1" &&
        grep -qF ".github/CODEOWNERS" "$1" &&
        grep -qF "noted `recreated`" "$1"' sh \
    "$STANDARDIZE_REFS/copier-gotchas.md"
expect_ok "audit class K sets _skip_if_exists paths aside before dispositioning" \
    sh -c 'grep -qF "Check BOTH re-creation carve-outs" "$1" &&
        grep -qF "invisible to the deleted-path scan" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
# The sweep's own MISSING lines assert permanence inline, so they carry the
# qualifier too — a flat "will NOT restore it" is false for these paths.
expect_ok "the MISSING annotations qualify permanence for _skip_if_exists" \
    sh -c 'test "$(grep -cF \
        "unless _skip_if_exists or the render'\''s own .gitignore covers it" "$1")" -eq 2 &&
        ! grep -qF "a copier update will NOT restore it" "$1"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "update guidance routes created rows to their own list and check" \
    sh -c 'grep -qF "### Files the update created" "$1" &&
        grep -qF "noted \`recreated\`" "$1" &&
        grep -qF "A rehearsal has one way to be" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The empty-result sentence claimed every both-renders path EXISTS in the repo,
# which is false the moment a filtered row exists — and one nearly always does.
expect_ok "the empty-result sentence claims only what the report established" \
    sh -c 'grep -qF "No unexplained silent" "$1" &&
        test "$(grep -cF "every path present in both renders exists" "$1")" \
            -eq 1' sh \
    "$UPDATE_PROCEDURE"
expect_ok "audit drift class K routes MISSING to the non-adoption gotcha" \
    sh -c 'grep -qF "PERMANENT non-adoption candidate" "$1" &&
        grep -qF "(./copier-gotchas.md) §9" "$1"' sh \
    "$STANDARDIZE_REFS/mode-audit.md"
# The snippet duplicates ONE branch of diff-template.sh's `is_co_owned` by hand —
# the `docs/`/`specs/` prose case — because a markdown recipe cannot source a
# shell function. Check the SHAPE, not only the literals: a copy that kept the
# old one-line `docs/* | specs/*) return 0 ;;` still matches a literal `docs/*`
# grep while classifying a missing generated asset as owned prose and collapsing
# it out of the report. So require the tree label to stand alone on its line (the
# pre-filter form cannot) and the Markdown basename test directly under it.
expect_ok "co-owned prose globs agree between diff-template.sh and the non-adoption snippet" \
    sh -c 'for f in "$1" "$2"; do
        # shell-robustness: begin-exempt — the pipeline is quoted text passed to another shell, not code this shell runs
        grep -A2 -E "^[[:space:]]*docs/\* \| specs/\*\)$" "$f" |
            grep -qF "case \"\${1##*/}\" in" || exit 1
        grep -A2 -E "^[[:space:]]*docs/\* \| specs/\*\)$" "$f" |
            grep -qE "^[[:space:]]*\*\.md\) return 0 ;;$" || exit 1
        # shell-robustness: end-exempt
    done' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh" "$GU_NONADOPT_SNIPPET"
# The pointer to that duplicate has to name the symbol that exists and the
# behaviour it actually has. It named `nonadoption_is_collapsible_prose` and said
# prose absences are collapsed OUT of the report, while the real helper is
# `nonadoption_is_doc_prose` and §5 tables those absences with a note — a comment
# that sends the next edit to a missing function and describes the opposite
# outcome is worse than no comment.
expect_ok "the co-ownership sync comment names the helper that exists" \
    sh -c '! grep -qF "nonadoption_is_collapsible_prose" "$1" &&
        grep -qF "nonadoption_is_doc_prose" "$1"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "the named helper is the one the snippet actually defines" \
    grep -qF "nonadoption_is_doc_prose() {" "$GU_NONADOPT_SNIPPET"
# Every repo-path resolution in diff-template.sh runs through the
# physical-parent guard, equivalence included. `find` does not descend a
# symlinked directory and `resolve_variant` refuses one before the equivalence
# walk is ever reached, so no repro survives today — which is exactly why the
# guard is worth pinning: the invariant should hold because it is checked, not
# because two unrelated behaviours happen to cover for it.
# Every path this script hands git comes from the RENDER's own file names, so a
# `*`, `?`, or `[` in one is a filename and never pathspec magic. Without
# `--literal-pathspecs` a rendered `docs/[a].md` silently answers about
# `docs/a.md` — wrong index mode, wrong staged verdict, and for the clobber gate
# a claim about a file nobody touched.
# shell-robustness: begin-exempt — the pipeline runs in a `sh -c`/`bash -c` subshell that never enables pipefail
expect_ok "every pathspec-taking git probe is pinned literal" \
    sh -c 'test "$(grep -cE "(ls-files|ls-tree|diff --cached)[^|]*-- \"" "$1")" -gt 0 &&
        ! grep -nE "git -C \"\\\$target\" (ls-files|ls-tree|diff)" "$1" |
            grep -qv -- "--literal-pathspecs" &&
        test "$(grep -c -- "--literal-pathspecs" "$1")" -ge 3' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
expect_ok "the equivalence walk honors the physical-parent guard" \
    sh -c 'test "$(sed -n "/^has_repo_equivalent() {/,/^has_nested_terraform_root() {/p" "$1" |
        grep -c "repo_parent_diverges")" -ge 3 &&
        sed -n "/^has_nested_terraform_root() {/,/^}$/p" "$1" |
            grep -qF "repo_parent_diverges" &&
        sed -n "/^has_nested_terraform_root() {/,/^}$/p" "$1" |
            grep -qF -- "-name .terraform -prune"' sh \
    "$STANDARDIZE_ASSETS/diff-template.sh"
# shell-robustness: end-exempt
# The REST of the co-owned list must NOT be mirrored. Co-ownership is a content
# exemption and absence is not content, so a missing AGENTS.md or LICENSE is a
# row like any other — now carrying a note instead of vanishing into a count.
expect_ok "the non-adoption snippet treats documentation prose as a note" \
    sh -c 'grep -qF "nonadoption_is_doc_prose" "$1" &&
        grep -qF "nonadoption_add_note co-owned-prose" "$1" &&
        ! grep -qE "^[[:space:]]*(AGENTS\.md|README\.md|SECURITY\.md)[[:space:]]*\|" "$1" &&
        ! grep -qF ".devcontainer/config/zshrc)" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# THE structural invariant, and the one that ends the finding family five rounds
# of review kept re-opening: evidence ANNOTATES a row, it never withholds one.
# Concretely — the `class` column may only ever hold a transition class, and the
# former filter classes survive only as note strings. Re-introducing any of them
# as a class is exactly how a path silently stops being reported.
expect_ok "non-adoption evidence annotates rows and never suppresses them" \
    sh -c 'grep -qF "nonadoption_add_note" "$1" &&
        grep -qF "nonadoption_collect_notes" "$1" &&
        ! grep -qF "nonadoption_filtered_class" "$1" &&
        ! grep -qF "NONADOPT_FILTERED" "$1" &&
        ! grep -qE "NONADOPT_CLASS=(co-owned|ignored-policy|filtered-known|gitkeep)" "$1" &&
        ! grep -qF "NONADOPT_FILTERED" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "the class column carries only the observed classes" \
    sh -c 'assigned="$(grep -oE "NONADOPT_CLASS=[a-z-]+" "$1" |
            sed "s/NONADOPT_CLASS=//" | LC_ALL=C sort -u | paste -sd, -)"
        test "$assigned" = \
            "created,deleted,nonadopt-both,unknown-until-apply"' sh \
    "$GU_NONADOPT_SNIPPET"
# The inversion itself: the snippet copies the tree, runs §2's own update against
# the copy, and reads the result. If any of these three go missing it has gone
# back to predicting.
expect_ok "the snippet rehearses the apply instead of modelling it" \
    sh -c 'grep -qF "git clone --no-hardlinks" "$1" &&
        grep -qF "run_guarded_copier update --trust --defaults --skip-tasks" "$1" &&
        grep -qF "nonadoption_path_present" "$1" &&
        grep -qF "apply-created" "$1" &&
        grep -qF "apply-deleted" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# The rehearsal must mirror §2 or it predicts nothing. These are the flags §2
# uses; `--skip-tasks` and the destination are the only sanctioned differences.
# The scratch is a CLONE. Three rounds of review each found another property the
# hand-built copy-init-add-commit construction failed to reproduce; a clone
# reproduces the index by definition, so the guard is that the construction has
# not grown back. `xargs -r`, `cp --parents` and `cp -t` are GNU-only and this
# recipe supports macOS bash 3.2, so they stay banned outright.
expect_ok "the rehearsal clones rather than rebuilding the scratch repository" \
    sh -c 'grep -qF "git clone --no-hardlinks --quiet . \"\$NONADOPT_SCRATCH/repo\"" "$1" &&
        ! grep -qE "^[^#]*(xargs|cp --parents|cp -t |cp -a)" "$1" &&
        ! grep -qF "git ls-files >" "$1" &&
        ! grep -qF "check-ignore --stdin" "$1" &&
        ! grep -qF "rehearsal baseline" "$1" &&
        ! grep -qF "scratch-copy-paths" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# Ignored files are untracked, so the clone omits them; only the MANAGED ones are
# overlaid. Unmanaged caches stay behind — copier cannot consult them, being in
# neither render inventory nor the index.
expect_ok "the rehearsal overlays managed ignored paths only" \
    sh -c 'grep -qF "\$GUARDED_STATE/ignored-existing-paths" "$1" &&
        grep -qF "scratch-overlay-paths" "$1" &&
        grep -qF "sed '\''s#^#./#'\''" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# The rehearsal (#2042), the preview and the real apply (#2043) all live in the
# asset; the three invocations are compared as argument lists rather than each
# grepped alone: one argument set — `--trust --defaults`, the frozen `--vcs-ref`
# and `--data-file` — plus exactly `--skip-tasks` and the scratch destination
# for the rehearsal and exactly `--pretend` for the preview.
copier_update_args() { # copier_update_args <file> <first line of the call>
    python3 - "$1" "$2" <<'PY_ARGS'
import shlex
import sys

lines = open(sys.argv[1]).read().splitlines()
sites = [i for i, line in enumerate(lines) if line.strip() == sys.argv[2]]
if len(sites) != 1:
    sys.exit(f"expected one call site, found {len(sites)}")
call, i = "", sites[0]
while True:
    line = lines[i].strip()
    call += " " + line.removesuffix("\\")
    if not line.endswith("\\"):
        break
    i += 1
words = shlex.split(call.replace("; then", " ").replace(" ||", " "), posix=False)
words = words[1:] if words[0] == "if" else words
if words[:2] != ["run_guarded_copier", "update"]:
    sys.exit(f"not a guarded copier update: {call}")
print("\n".join(words[2:]))
PY_ARGS
}
rehearsal_mirrors_apply() {
    local rehearsal preview apply
    rehearsal="$(copier_update_args "$GUARDED_UPDATE" \
        'run_guarded_copier update --trust --defaults --skip-tasks \')" &&
        preview="$(copier_update_args "$GUARDED_UPDATE" \
            'run_guarded_copier update --trust --defaults --pretend \')" &&
        apply="$(copier_update_args "$GUARDED_UPDATE" \
            'if run_guarded_copier update --trust --defaults \')" || return 1
    [ "$(grep -cxF -- --skip-tasks <<<"$rehearsal")" -eq 1 ] &&
        [ "$(tail -n 1 <<<"$rehearsal")" = '"$NONADOPT_SCRATCH/repo"' ] &&
        [ "$(sed '$d' <<<"$rehearsal" | grep -vxF -- --skip-tasks)" = "$apply" ] &&
        [ "$(grep -cxF -- --pretend <<<"$preview")" -eq 1 ] &&
        [ "$(grep -vxF -- --pretend <<<"$preview")" = "$apply" ] &&
        [ "$apply" = "$(printf '%s\n' --trust --defaults \
            '--vcs-ref="$HARMON_INIT_COMMIT"' '--data-file="$REVIEWED_DATA"')" ]
}
expect_ok "the rehearsal mirrors the real update's invocation" \
    rehearsal_mirrors_apply
expect_ok "non-adoption snippet requires template-side declaration for ignored-policy" \
    sh -c 'grep -qF "nonadoption_is_render_ignored" "$1" &&
        grep -qF "check-ignore -q --no-index" "$1" &&
        grep -qF "core.excludesFile=/dev/null" "$1" &&
        grep -qF "repo-ignored-only" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "non-adoption snippet records the known-false verdict either way" \
    sh -c 'grep -qF "nonadoption_known_false_note" "$1" &&
        grep -qF "nonadoption_has_adr_log" "$1" &&
        grep -qF "nonadoption_has_nested_terraform" "$1" &&
        grep -qF "nonadoption_has_prettier_config" "$1" &&
        grep -qF "unverified-equivalent" "$1" &&
        grep -qF "known-false-verified" "$1" &&
        ! grep -qE "^[[:space:]]*\.envrc\) return 0 ;;$" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# Each equivalence is held to the documented evidence, and each of these lines is
# the whole of that restriction — drop one and the check silently widens back to
# "something that looks vaguely like a replacement".
expect_ok "non-adoption snippet holds each equivalence to its documented evidence" \
    sh -c 'grep -qF "*-record-architecture-decisions.md) return 0 ;;" "$1" &&
        grep -qF "test -f docs/decisions/index.md || test -f docs/decisions/README.md" "$1" &&
        grep -qF -- "-name .terraform -prune -o -type f -name" "$1" &&
        grep -qF "yq -r '\''.prettier // \"\"'\'' package.json" "$1" &&
        ! grep -qF "grep -q '\''\"prettier\"'\'' package.json" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# The Brewfile stays disclosed. There is no filter list to re-enter now, so the
# guard is simply that its chezmoi evidence lands as a note.
expect_ok "non-adoption snippet discloses the contested Brewfile instead of filtering it" \
    sh -c 'grep -qF "nonadoption_add_note \"chezmoi-managed — verify per mode-audit class K\"" "$1" &&
        grep -qF "nonadoption_has_chezmoi_brewfile" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
expect_ok "update guidance states its snippet execution assumptions up front" \
    sh -c 'grep -qF "on both the producer and the consumer" "$1" &&
        grep -qF "file 1 is not in sorted order" "$1"' sh \
    "$UPDATE_PROCEDURE"
# The non-adoption classifier deliberately does NOT learn about the class, and
# the reason is recorded where the next person to mirror something will look.
expect_ok "the non-adoption classifier records why OWNED is not mirrored into it" \
    grep -qF "diff-template.sh's OWNED class is likewise absent" \
    "$UPDATE_PROCEDURE"
GU_TEMPLATE="$TMPROOT/guarded-update-source"
GU_REMOTE="$TMPROOT/guarded-update-remote.git"
GU_TARGET="$TMPROOT/guarded-update-target"
GU_SNAPSHOT="$TMPROOT/guarded-update-snapshot"
GU_CACHE="$TMPROOT/guarded-update-cache"
mkdir -p "$GU_TEMPLATE/template"
mkdir -p "$GU_CACHE"
cat >"$GU_TEMPLATE/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_skip_if_exists:
  - .github/CODEOWNERS
project_name:
  type: str
  default: Guarded Update
use_foreman:
  type: bool
  default: false
use_coderabbit:
  type: bool
  default: false
use_codeql:
  type: bool
  default: false
codeql_languages:
  type: yaml
  default: []
EOF
cat >"$GU_TEMPLATE/template/.copier-answers.yml.jinja" <<'EOF'
{{ _copier_answers|to_nice_yaml -}}
EOF
mkdir -p "$GU_TEMPLATE/template/.vscode"
printf '%s\n' '.vscode/*' \
    '!.vscode/settings.json' \
    '!.vscode/legacy.json' >"$GU_TEMPLATE/template/.gitignore"
printf '%s\n' '{"setting":"baseline"}' \
    >"$GU_TEMPLATE/template/.vscode/settings.json"
printf '%s\n' '{"legacy":"baseline"}' \
    >"$GU_TEMPLATE/template/.vscode/legacy.json"
printf '%s\n' 'baseline' >"$GU_TEMPLATE/template/version.txt"
# A `_skip_if_exists` path, so the fixture's real update exercises the one
# behaviour the classifier used to need dedicated pattern-matching code for.
# Nothing reads the pattern list any more — the scratch apply just watches the
# file come back.
mkdir -p "$GU_TEMPLATE/template/.github"
printf '%s\n' '* @owner' >"$GU_TEMPLATE/template/.github/CODEOWNERS"
# Three non-adoption fixtures, all plain files that no ignore rule covers:
#   shared-note.md — shipped by BOTH renders, byte-identical across the range,
#                    and deleted from the repo below. The merge has no diff to
#                    apply and reads the absence as the user's own deletion:
#                    `nonadopt-both`, the permanent blind spot.
#   retired-doc.md — baseline-only (the target template drops it) while the repo
#                    still carries it: `delete-expected`.
#   new-doc.md     — added by the target template only: `new-in-target`.
printf '%s\n' 'shared across the update range' \
    >"$GU_TEMPLATE/template/shared-note.md"
printf '%s\n' 'retired by the target template' \
    >"$GU_TEMPLATE/template/retired-doc.md"
git_init "$GU_TEMPLATE"
git_commit_all "$GU_TEMPLATE" "baseline template"
GU_BASELINE="$(git -C "$GU_TEMPLATE" rev-parse HEAD)"
git -C "$GU_TEMPLATE" tag v1.0.0
copier copy --trust --defaults --vcs-ref=v1.0.0 \
    "$GU_TEMPLATE" "$GU_TARGET" >/dev/null
GU_CANONICAL_SOURCE=https://github.com/example/guarded-update
GU_CANONICAL_SOURCE="$GU_CANONICAL_SOURCE" \
    yq -i '._src_path = strenv(GU_CANONICAL_SOURCE)' \
    "$GU_TARGET/.copier-answers.yml"
mkdir -p "$GU_TARGET/.vscode"
printf '%s\n' '.vscode/*' >"$GU_TARGET/.gitignore"
printf '%s\n' '{"setting":"custom"}' >"$GU_TARGET/.vscode/settings.json"
printf '%s\n' '{"legacy":"custom"}' >"$GU_TARGET/.vscode/legacy.json"
git_init "$GU_TARGET"
git_commit_all "$GU_TARGET" "generated baseline"
GU_TARGET_REAL="$(cd "$GU_TARGET" && pwd -P)"
# The repo declines shared-note.md, staged and committed — indistinguishable
# from a removal made three versions ago and forgotten. From here on no
# `copier update` will ever put it back, and none will say so.
rm "$GU_TARGET/shared-note.md" "$GU_TARGET/.github/CODEOWNERS"
git_commit_all "$GU_TARGET" "drop the shared note and CODEOWNERS"

printf '%s\n' 'target' >"$GU_TEMPLATE/template/version.txt"
printf '%s\n' '.vscode/*' \
    '!.vscode/settings.json' \
    '!.vscode/new.json' \
    >"$GU_TEMPLATE/template/.gitignore"
printf '%s\n' '{"setting":"target"}' \
    >"$GU_TEMPLATE/template/.vscode/settings.json"
rm "$GU_TEMPLATE/template/.vscode/legacy.json"
printf '%s\n' '{"new":"target"}' \
    >"$GU_TEMPLATE/template/.vscode/new.json"
rm "$GU_TEMPLATE/template/retired-doc.md"
printf '%s\n' 'added by the target template' \
    >"$GU_TEMPLATE/template/new-doc.md"
cat >>"$GU_TEMPLATE/copier.yml" <<'EOF'
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
  type: yaml
  default: []
deploy_preview:
  type: bool
  default: false
preview_region:
  type: str
  default: iad
  when: "{{ deploy_preview }}"
hidden_rollout:
  type: str
  default: internal
  when: false
EOF
git_commit_all "$GU_TEMPLATE" "target template"
GU_TARGET_COMMIT="$(git -C "$GU_TEMPLATE" rev-parse HEAD)"
git -C "$GU_TEMPLATE" tag v2.0.0
git clone --bare "$GU_TEMPLATE" "$GU_REMOTE" >/dev/null 2>&1
git -C "$GU_TEMPLATE" tag v9.9.9
git clone --no-local --no-checkout "$GU_REMOTE" "$GU_SNAPSHOT" >/dev/null 2>&1
git -C "$GU_SNAPSHOT" remote remove origin
expect_fail "guarded snapshot excludes local-only template tags" \
    git -C "$GU_SNAPSHOT" rev-parse --verify refs/tags/v9.9.9
printf '%s\n' '/.copier-guarded-update/' >>"$GU_TARGET/.git/info/exclude"
mkdir "$GU_TARGET/.copier-guarded-update"
git -C "$GU_TARGET" rev-parse HEAD \
    >"$GU_TARGET/.copier-guarded-update/start-head"
printf '%s\n' branch:main \
    >"$GU_TARGET/.copier-guarded-update/start-checkout"
git -C "$GU_TARGET" hash-object "$GU_TARGET/.copier-answers.yml" \
    >"$GU_TARGET/.copier-guarded-update/canonical-answers-oid"
printf '%s\n' "$GU_TARGET_COMMIT" \
    >"$GU_TARGET/.copier-guarded-update/target-commit"
printf '%s\n' "$GU_SNAPSHOT" \
    >"$GU_TARGET/.copier-guarded-update/template-path"
printf '%s\n' "$GU_CACHE" \
    >"$GU_TARGET/.copier-guarded-update/cache-path"
cp "$GU_TARGET/.copier-answers.yml" \
    "$GU_TARGET/.copier-guarded-update/original-answers.yml"
git -C "$GU_SNAPSHOT" show "$GU_BASELINE":copier.yml |
    yq -r 'keys | .[] | select(test("^_") | not)' |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/baseline-questions"
git -C "$GU_SNAPSHOT" show "$GU_TARGET_COMMIT":copier.yml |
    yq -r 'keys | .[] | select(test("^_") | not)' |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/target-questions"
LC_ALL=C comm -13 \
    "$GU_TARGET/.copier-guarded-update/baseline-questions" \
    "$GU_TARGET/.copier-guarded-update/target-questions" \
    >"$GU_TARGET/.copier-guarded-update/new-question-candidates"
GU_DISCOVERY="$TMPROOT/guarded-update-discovery"
yq 'with_entries(select(.key | test("^_") | not))' \
    "$GU_TARGET/.copier-guarded-update/original-answers.yml" \
    >"$GU_TARGET/.copier-guarded-update/discovery-data.yml"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_SNAPSHOT" "$GU_DISCOVERY" >/dev/null
yq -r 'keys | .[] | select(test("^_") | not)' \
    "$GU_DISCOVERY/.copier-answers.yml" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/active-target-questions"
LC_ALL=C comm -12 \
    "$GU_TARGET/.copier-guarded-update/new-question-candidates" \
    "$GU_TARGET/.copier-guarded-update/active-target-questions" \
    >"$GU_TARGET/.copier-guarded-update/active-new-questions"
{
    cat "$GU_TARGET/.copier-guarded-update/active-new-questions"
    printf '%s\n' use_foreman use_coderabbit use_codeql codeql_languages \
        use_codex_review use_skills_sync skill_categories
} |
    LC_ALL=C sort -u |
    LC_ALL=C comm -12 - \
        "$GU_TARGET/.copier-guarded-update/active-target-questions" \
        >"$GU_TARGET/.copier-guarded-update/reviewed-keys"
USE_FOREMAN=true USE_CODERABBIT=false USE_CODEQL=true \
    USE_CODEX_REVIEW=true USE_CODEX_CLOUD_REVIEW=true \
    USE_SKILLS_SYNC=true SKILL_CATEGORIES='["universal"]' \
    CODEQL_LANGUAGES='["javascript-typescript"]' DEPLOY_PREVIEW=true \
    yq -n -o=yaml \
    '{"use_foreman": (strenv(USE_FOREMAN) == "true"),
      "use_coderabbit": (strenv(USE_CODERABBIT) == "true"),
      "use_codeql": (strenv(USE_CODEQL) == "true"),
      "use_codex_review": (strenv(USE_CODEX_REVIEW) == "true"),
      "use_codex_cloud_review": (strenv(USE_CODEX_CLOUD_REVIEW) == "true"),
      "use_skills_sync": (strenv(USE_SKILLS_SYNC) == "true"),
      "skill_categories": (strenv(SKILL_CATEGORIES) | from_json),
      "codeql_languages": (strenv(CODEQL_LANGUAGES) | from_json),
      "deploy_preview": (strenv(DEPLOY_PREVIEW) == "true")}' \
    >"$GU_TARGET/.copier-guarded-update/reviewed-data.yml"
expect_fail "first discovery excludes a conditional question whose controller defaults off" \
    grep -qxF preview_region \
    "$GU_TARGET/.copier-guarded-update/active-target-questions"
yq eval-all \
    'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    >"$GU_TARGET/.copier-guarded-update/discovery-data.next.yml"
GU_DISCOVERY_SECOND="$TMPROOT/guarded-update-discovery-second"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET/.copier-guarded-update/discovery-data.next.yml" \
    "$GU_SNAPSHOT" "$GU_DISCOVERY_SECOND" >/dev/null
yq -r 'keys | .[] | select(test("^_") | not)' \
    "$GU_DISCOVERY_SECOND/.copier-answers.yml" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/active-target-questions"
LC_ALL=C comm -12 \
    "$GU_TARGET/.copier-guarded-update/new-question-candidates" \
    "$GU_TARGET/.copier-guarded-update/active-target-questions" \
    >"$GU_TARGET/.copier-guarded-update/active-new-questions"
{
    cat "$GU_TARGET/.copier-guarded-update/active-new-questions"
    printf '%s\n' use_foreman use_coderabbit use_codeql codeql_languages \
        use_codex_review use_skills_sync skill_categories
} |
    LC_ALL=C sort -u |
    LC_ALL=C comm -12 - \
        "$GU_TARGET/.copier-guarded-update/active-target-questions" \
        >"$GU_TARGET/.copier-guarded-update/reviewed-keys"
PREVIEW_REGION=ord yq -i \
    '.preview_region = strenv(PREVIEW_REGION)' \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml"
find "$GU_DISCOVERY_SECOND" \( -type f -o -type l \) -print |
    sed "s#^$GU_DISCOVERY_SECOND/##" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/target-managed-paths"
GU_BASELINE_DISCOVERY="$TMPROOT/guarded-update-baseline-discovery"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_BASELINE" \
    --data-file="$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_SNAPSHOT" "$GU_BASELINE_DISCOVERY" >/dev/null
find "$GU_BASELINE_DISCOVERY" \( -type f -o -type l \) -print |
    sed "s#^$GU_BASELINE_DISCOVERY/##" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/baseline-managed-paths"
cat \
    "$GU_TARGET/.copier-guarded-update/baseline-managed-paths" \
    "$GU_TARGET/.copier-guarded-update/target-managed-paths" |
    LC_ALL=C sort -u \
        >"$GU_TARGET/.copier-guarded-update/managed-paths"
git -C "$GU_TARGET" hash-object \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    >"$GU_TARGET/.copier-guarded-update/reviewed-data-oid"
expect_ok "guarded review set derives every target-only Copier question" \
    sh -c 'grep -qxF deploy_preview "$1" &&
        grep -qxF preview_region "$1"' sh \
    "$GU_TARGET/.copier-guarded-update/active-new-questions"
expect_ok "second discovery activates a conditional question after controller review" \
    grep -qxF preview_region \
    "$GU_TARGET/.copier-guarded-update/active-target-questions"
cp "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml"
yq -i '.deploy_preview = false' \
    "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml"
printf '%s\n' '{}' \
    >"$GU_TARGET/.copier-guarded-update/stale-active-reviewed.yml"
yq -r 'keys | .[] | select(test("^_") | not)' \
    "$GU_DISCOVERY/.copier-answers.yml" |
    LC_ALL=C sort -u |
    while IFS= read -r active_key; do
        if ACTIVE_KEY="$active_key" yq -e \
            'has(strenv(ACTIVE_KEY))' \
            "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml" \
            >/dev/null; then
            ACTIVE_VALUE="$(
                ACTIVE_KEY="$active_key" yq -o=json -I=0 \
                    '.[strenv(ACTIVE_KEY)]' \
                    "$GU_TARGET/.copier-guarded-update/stale-reviewed-data.yml"
            )"
            ACTIVE_KEY="$active_key" ACTIVE_VALUE="$ACTIVE_VALUE" yq -i \
                '.[strenv(ACTIVE_KEY)] =
                    (strenv(ACTIVE_VALUE) | from_json)' \
                "$GU_TARGET/.copier-guarded-update/stale-active-reviewed.yml"
        fi
    done
yq eval-all \
    'select(fileIndex == 0) * select(fileIndex == 1)' \
    "$GU_TARGET/.copier-guarded-update/discovery-data.yml" \
    "$GU_TARGET/.copier-guarded-update/stale-active-reviewed.yml" \
    >"$GU_TARGET/.copier-guarded-update/stale-discovery-data.yml"
GU_DISCOVERY_STALE="$TMPROOT/guarded-update-discovery-stale"
copier copy --trust --defaults --skip-tasks \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET/.copier-guarded-update/stale-discovery-data.yml" \
    "$GU_SNAPSHOT" "$GU_DISCOVERY_STALE" >/dev/null
expect_fail "fixed-point filtering drops stale values from newly inactive questions" \
    yq -e 'has("preview_region")' \
    "$GU_DISCOVERY_STALE/.copier-answers.yml"
expect_fail "guarded review set excludes hidden target-only questions" \
    grep -qxF hidden_rollout \
    "$GU_TARGET/.copier-guarded-update/reviewed-keys"
expect_ok "guarded review data covers every required reviewed question" \
    sh -c 'while IFS= read -r key; do
        KEY="$key" yq -e "has(strenv(KEY))" "$1" >/dev/null || exit 1
    done <"$2"' sh \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml" \
    "$GU_TARGET/.copier-guarded-update/reviewed-keys"
expect_ok "guarded update carries valid Codex classifier prerequisites" \
    sh -c 'test "$(yq -r ".use_codex_cloud_review" "$1")" = true &&
        test "$(yq -r ".use_codex_review" "$1")" = true &&
        test "$(yq -r ".use_skills_sync" "$1")" = true &&
        yq -e ".skill_categories | contains([\"universal\"])" "$1" \
            >/dev/null' sh \
    "$GU_TARGET/.copier-guarded-update/reviewed-data.yml"
while IFS= read -r managed_path; do
    if git -C "$GU_TARGET" check-ignore -q -- "$managed_path"; then
        printf '%s\n' "$managed_path"
    fi
done <"$GU_TARGET/.copier-guarded-update/managed-paths" \
    >"$GU_TARGET/.copier-guarded-update/ignored-managed-paths"
: >"$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
: >"$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
while IFS= read -r ignored_path; do
    if test -e "$GU_TARGET/$ignored_path" ||
        test -L "$GU_TARGET/$ignored_path"; then
        printf '%s\n' "$ignored_path" \
            >>"$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
    else
        printf '%s\n' "$ignored_path" \
            >>"$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
    fi
done <"$GU_TARGET/.copier-guarded-update/ignored-managed-paths"
tar -C "$GU_TARGET" \
    -cf "$GU_TARGET/.copier-guarded-update/ignored-backup.tar" \
    -T "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
git -C "$GU_TARGET" hash-object \
    "$GU_TARGET/.copier-guarded-update/ignored-backup.tar" \
    >"$GU_TARGET/.copier-guarded-update/ignored-backup-oid"
git -C "$GU_TARGET" hash-object \
    "$GU_TARGET/.copier-guarded-update/ignored-managed-paths" \
    >"$GU_TARGET/.copier-guarded-update/ignored-managed-paths-oid"
printf '%s\n' ready \
    >"$GU_TARGET/.copier-guarded-update/ignored-snapshot-ready"
expect_ok "guarded ignored backup is derived from the task-free target render" \
    grep -qxF .vscode/settings.json \
    "$GU_TARGET/.copier-guarded-update/ignored-managed-paths"
expect_ok "guarded ignored backup includes baseline-only existing paths" \
    grep -qxF .vscode/legacy.json \
    "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
expect_ok "guarded ignored backup records target-only absent paths" \
    grep -qxF .vscode/new.json \
    "$GU_TARGET/.copier-guarded-update/ignored-absent-paths"

# Run the §1 non-adoption classifier, extracted from the asset's `rehearse`
# (#2042), against this fixture's frozen inventories and its two real discovery
# renders. Extracting the marked code and executing it on hand-built state
# proves the classifier itself works, case by case; the rehearse cases near the
# prepare/discover fixture run the whole subcommand. Everything it needs already
# exists here: both managed-path inventories, ignored-absent-paths, and both
# renders.
# The snippet now REHEARSES the update against a scratch copy instead of
# modelling it, so it needs copier and the guarded wrapper. The wrapper is
# extracted from the same asset rather than restated here — a rehearsal of a
# differently-configured copier would prove nothing about §2's invocation.
GU_NONADOPT_RUNNER="$TMPROOT/nonadoption-runner.sh"
{
    printf '%s\n' 'set -eu'
    sed -n '/^run_guarded_copier() {/,/^}/p' "$UPDATE_PROCEDURE"
    cat "$GU_NONADOPT_SNIPPET"
} >"$GU_NONADOPT_RUNNER"
expect_ok "the guarded copier wrapper is extractable alongside the snippet" \
    sh -c 'grep -qF "run_guarded_copier() {" "$1" &&
        grep -qF "COPIER_CACHE_DIR=" "$1"' sh "$GU_NONADOPT_RUNNER"
expect_ok "the non-adoption scratch canonicalizes macOS temp-path aliases" \
    sh -c 'grep -qF '\''mktemp -d "${TMPDIR:-/tmp}/copier-nonadoption-apply-XXXXXX"'\'' "$1" &&
        grep -qF '\''NONADOPT_SCRATCH="$(cd "$NONADOPT_SCRATCH" && pwd -P)"'\'' "$1"' sh \
    "$GU_NONADOPT_RUNNER"
GU_RECONCILE="$TMPROOT/nonadoption-reconcile.sh"
{
    printf '%s\n' 'set -eu' 'GUARDED_STATE=.copier-guarded-update'
    sed -n '/^nonadoption_reconcile() {/,/^}$/p' "$UPDATE_PROCEDURE"
    printf '%s\n' 'nonadoption_reconcile'
} >"$GU_RECONCILE"
expect_ok "the reconciliation recipe is extractable from the guidance" \
    sh -c 'grep -qF "RECONCILE_BAD" "$1" && grep -qF "nonadoption_reconcile" "$1"' sh \
    "$GU_RECONCILE"
printf '{}\n' >"$GU_TARGET/.copier-guarded-update/nonadoption-reviewed.yml"
gu_nonadopt_classify() {
    (cd "$GU_TARGET" &&
        GUARDED_STATE=.copier-guarded-update \
            BASELINE_DISCOVERY="$GU_BASELINE_DISCOVERY" \
            TARGET_DISCOVERY="$GU_DISCOVERY_SECOND" \
            GUARDED_TEMPLATE="$GU_SNAPSHOT" \
            HARMON_INIT_SOURCE="$GU_CANONICAL_SOURCE" \
            GUARDED_COPIER_CACHE="$GU_CACHE" \
            HARMON_INIT_COMMIT="$GU_TARGET_COMMIT" \
            REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
            bash -eu "$GU_NONADOPT_RUNNER" >/dev/null)
}
# The rehearsal's `mktemp -d -t` honours TMPDIR, so it is pointed at a directory
# only this fixture uses. Counting `copier-nonadoption-apply-*` in the SHARED
# tmpdir was a race: another guarded run on the same machine owns directories
# matching that glob, and this suite has no business counting — or later
# deleting — them.
GU_SCRATCH_TMP="$TMPROOT/gu-rehearsal-tmp"
mkdir -p "$GU_SCRATCH_TMP"
gu_nonadopt_classify_private_tmp() {
    (
        TMPDIR="$GU_SCRATCH_TMP"
        export TMPDIR
        gu_nonadopt_classify
    )
}
expect_ok "non-adoption classifier rehearses the apply and runs clean under bash -eu" \
    gu_nonadopt_classify_private_tmp
# The rehearsal must not disturb the tree it rehearses on: it copies, applies to
# the copy, and removes the copy. A guarded run whose observation step mutated
# the worktree would be the worst possible bug in this design.
expect_ok "the scratch rehearsal leaves the real worktree untouched" \
    sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$GU_TARGET"
# Emptiness of a directory nobody else writes to, rather than a count of a shared
# one: an exact assertion instead of a racy inequality.
expect_ok "the scratch rehearsal removes its own copy" \
    sh -c 'test -z "$(ls -A "$1")"' sh "$GU_SCRATCH_TMP"
GU_NONADOPT_TSV="$GU_TARGET/.copier-guarded-update/nonadoption-report.tsv"
# Every row below is an OBSERVATION of a real copier apply against a copy of this
# fixture, not a prediction about one. The assertions further down re-check each
# against what the fixture's own real update actually does.
expect_ok "the rehearsal observes a both-renders absence copier declines to adopt" \
    grep -qxF "$(printf 'shared-note.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NONADOPT_TSV"
expect_ok "the rehearsal observes the template-side deletion" \
    grep -qxF "$(printf 'retired-doc.md\tdeleted\tn/a-removed\tbaseline-only\t-')" \
    "$GU_NONADOPT_TSV"
expect_ok "the rehearsal observes a target-only file being created" \
    grep -qxF "$(printf 'new-doc.md\tcreated\tn/a-new\ttarget-only\tnew-in-target')" \
    "$GU_NONADOPT_TSV"
# The case that used to need `_skip_if_exists` parsing, gitwildmatch basename
# rules and a dedicated class. It is now just a file that came back, seen.
expect_ok "the rehearsal observes a _skip_if_exists path being recreated" \
    grep -qxF "$(printf '.github/CODEOWNERS\tcreated\tno\tbaseline+target\trecreated')" \
    "$GU_NONADOPT_TSV"
# ...and no code in the snippet knows what `_skip_if_exists` is any more.
expect_ok "the snippet reads no _skip_if_exists patterns at all" \
    sh -c '! grep -qF "_skip_if_exists // []" "$1" &&
        ! grep -qF "nonadoption_is_recreated_on_update" "$1" &&
        ! grep -qF "skip-if-exists-patterns" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# .vscode/new.json is repo-ignored but the target template NEGATES it, so the
# template is saying as loudly as a .gitignore can that the file is meant to be
# tracked. The class comes from watching the apply; the note still records whose
# rule it was.
expect_ok "a repo-only ignore is recorded as evidence, not as adoption policy" \
    grep -qxF "$(printf '.vscode/new.json\tcreated\tn/a-new\ttarget-only\tnew-in-target; repo-ignored-only')" \
    "$GU_NONADOPT_TSV"
# Adopted paths carry no row — otherwise every render file would be a finding
# and the report would be as useless as no report.
expect_fail "the rehearsal stays silent about paths the repo already has" \
    grep -qF version.txt "$GU_NONADOPT_TSV"
chmod -R a-w "$GU_SNAPSHOT"

# --- note machinery, on a real copier fixture --------------------------------
# The classes come from watching a real apply now, so this fixture no longer
# tests classification at all — it tests the NOTE machinery, which is the part
# still made of judgement rather than observation. Both renders are the same
# commit, so every declined path is a plain `nonadopt-both` and the only thing
# that varies between rows is the evidence attached to them.
#
# It is a real copier template for the same reason everything else here is now:
# the snippet rehearses an apply, and there is nothing to rehearse against a
# hand-built directory.
GU_NA_ROOT="$TMPROOT/nonadoption-notes"
GU_NA_TPL="$GU_NA_ROOT/template"
GU_NA_REPO="$GU_NA_ROOT/repo"
GU_NA_BASE="$GU_NA_ROOT/baseline-render"
GU_NA_TGT="$GU_NA_ROOT/target-render"
GU_NA_STATE="$GU_NA_REPO/.copier-guarded-update"
GU_NA_CACHE="$GU_NA_ROOT/cache"
mkdir -p "$GU_NA_TPL/template" "$GU_NA_CACHE"
cat >"$GU_NA_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Notes
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$GU_NA_TPL/template/.copier-answers.yml.jinja"
na_tpl_file() {
    mkdir -p "$(dirname "$GU_NA_TPL/template/$1")"
    printf '%s\n' "${2:-rendered body}" >"$GU_NA_TPL/template/$1"
}
# Root co-owned prose (no note) versus documentation-tree prose (co-owned-prose).
na_tpl_file AGENTS.md
na_tpl_file docs/guide.md
# Non-prose under docs/ is not prose at all — the Markdown-only filter.
na_tpl_file docs/build.sh
# Drift class K seeds, each needing its documented equivalent verified.
na_tpl_file docs/decisions/0001-record-architecture-decisions.md
na_tpl_file docs/decisions/2026-10-06-record-architecture-decisions.md
na_tpl_file terraform/main.tf
na_tpl_file prettier.config.cjs
na_tpl_file Brewfile
# Ignore policy: local.json is ignored by BOTH sides, stray.md by the repo only.
na_tpl_file .vscode/local.json
na_tpl_file stray.md
printf '%s\n' '.vscode/*' >"$GU_NA_TPL/template/.gitignore"
# A dir stub, and a `.yml` whose `.yaml` twin the repo keeps instead.
na_tpl_file dir-stub/.gitkeep
na_tpl_file config.yml
na_tpl_file version.txt
git_init "$GU_NA_TPL"
# The .gitignore the template SHIPS also applies to the template repo, so
# `.vscode/local.json` would never be committed and never render. Force-add it:
# the point of this path is to be render-ignored AND present in the render.
git -C "$GU_NA_TPL" add -f template/.vscode/local.json
git_commit_all "$GU_NA_TPL" "notes template"
GU_NA_TPL_COMMIT="$(git -C "$GU_NA_TPL" rev-parse HEAD)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$GU_NA_TPL_COMMIT" \
    "$GU_NA_TPL" "$GU_NA_REPO" >/dev/null
git_init "$GU_NA_REPO"
printf '%s\n' '.vscode/*' 'stray.md' >"$GU_NA_REPO/.gitignore"
printf '%s\n' 'the other spelling' >"$GU_NA_REPO/config.yaml"
git_commit_all "$GU_NA_REPO" "generated"
printf '%s\n' '/.copier-guarded-update/' >>"$GU_NA_REPO/.git/info/exclude"
# Decline every interesting path. `.vscode/local.json` and `stray.md` are
# gitignored, so they were never committed; removing them is still a decline.
rm "$GU_NA_REPO/AGENTS.md" "$GU_NA_REPO/docs/guide.md" \
    "$GU_NA_REPO/docs/build.sh" \
    "$GU_NA_REPO/docs/decisions/0001-record-architecture-decisions.md" \
    "$GU_NA_REPO/docs/decisions/2026-10-06-record-architecture-decisions.md" \
    "$GU_NA_REPO/terraform/main.tf" "$GU_NA_REPO/prettier.config.cjs" \
    "$GU_NA_REPO/Brewfile" "$GU_NA_REPO/.vscode/local.json" \
    "$GU_NA_REPO/stray.md" "$GU_NA_REPO/dir-stub/.gitkeep" \
    "$GU_NA_REPO/config.yml"
git_commit_all "$GU_NA_REPO" "decline them all"
mkdir -p "$GU_NA_STATE"
printf '{}\n' >"$GU_NA_STATE/reviewed-data.yml"
# Both discovery renders are the same commit: nothing moved upstream, so every
# row reads `changed_in_range=no` and the notes are the only variable.
copier copy --trust --defaults --skip-tasks --vcs-ref="$GU_NA_TPL_COMMIT" \
    "$GU_NA_TPL" "$GU_NA_BASE" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$GU_NA_TPL_COMMIT" \
    "$GU_NA_TPL" "$GU_NA_TGT" >/dev/null
for na_side in BASE TGT; do
    eval "na_dir=\$GU_NA_$na_side"
    (cd "$na_dir" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$GU_NA_STATE/$(test "$na_side" = BASE &&
            printf baseline || printf target)-managed-paths"
done
: >"$GU_NA_STATE/ignored-absent-paths"
: >"$GU_NA_STATE/ignored-existing-paths"
while IFS= read -r na_path; do
    git -C "$GU_NA_REPO" check-ignore -q -- "$na_path" || continue
    test -e "$GU_NA_REPO/$na_path" ||
        printf '%s\n' "$na_path" >>"$GU_NA_STATE/ignored-absent-paths"
done <"$GU_NA_STATE/target-managed-paths"
na_classify() {
    (cd "$GU_NA_REPO" &&
        GUARDED_STATE=.copier-guarded-update \
            BASELINE_DISCOVERY="$GU_NA_BASE" \
            TARGET_DISCOVERY="$GU_NA_TGT" \
            GUARDED_TEMPLATE="$GU_NA_TPL" \
            HARMON_INIT_SOURCE="https://example.invalid/notes" \
            GUARDED_COPIER_CACHE="$GU_NA_CACHE" \
            HARMON_INIT_COMMIT="$GU_NA_TPL_COMMIT" \
            REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
            bash -eu "$GU_NONADOPT_RUNNER" >/dev/null)
}
GU_NA_TSV="$GU_NA_STATE/nonadoption-report.tsv"
expect_ok "note fixture rehearses its apply and runs clean under bash -eu" na_classify
# The invariant, over the whole report: only observed classes may appear.
expect_ok "every row carries an observed class" \
    sh -c 'bad="$(awk -F "\t" '"'"'$2 != "nonadopt-both" && $2 != "created" &&
            $2 != "deleted" { print $2 }'"'"' "$1" | LC_ALL=C sort -u | paste -sd, -)"
        test -z "$bad" || { echo "unexpected classes: $bad" >&2; exit 1; }' sh \
    "$GU_NA_TSV"
# Co-ownership is a content exemption and absence is not content: a missing
# AGENTS.md is a row with no explanation at all, which is the loudest row there
# is.
expect_ok "absent root co-owned prose is a row with no note" \
    grep -qxF "$(printf 'AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
expect_ok "documentation-tree prose is a row carrying its note" \
    grep -qxF "$(printf 'docs/guide.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose')" \
    "$GU_NA_TSV"
expect_ok "non-prose under docs/ is neither noted nor exempt" \
    grep -qxF "$(printf 'docs/build.sh\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
expect_ok "a dir stub is noted, not dropped" \
    grep -qxF "$(printf 'dir-stub/.gitkeep\tnonadopt-both\tno\tbaseline+target\tgitkeep')" \
    "$GU_NA_TSV"
# The twin is evidence now, full stop. Round 5 had to decide per class whether it
# counted as presence; the rehearsal answers that by watching.
expect_ok "a .yaml twin is recorded as evidence on the .yml row" \
    grep -qxF "$(printf 'config.yml\tnonadopt-both\tno\tbaseline+target\ttwin-exists: config.yaml')" \
    "$GU_NA_TSV"
# Ignore policy: the TEMPLATE's declaration grants the note, not the repo's. And
# look at the CLASS — this path comes back. A file the render's own .gitignore
# covers is invisible to copier's "the subproject deleted this" scan, so deleting
# it does not opt out of it: the apply renders it again. Every predictive
# revision of this classifier called this path `nonadopt-both` and told the
# operator it would stay gone. The rehearsal simply watched it reappear. It is
# also the cleanest illustration of why class and note are separate axes: the
# note says why the repo lacks the file, the class says copier is about to put it
# back, and both are true at once.
expect_ok "an ignore-policy path the apply recreates is classed created, not absent" \
    grep -qxF "$(printf '.vscode/local.json\tcreated\tno\tbaseline+target\trecreated; ignored-policy')" \
    "$GU_NA_TSV"
expect_ok "a path only the repo ignores is noted with whose rule it was" \
    grep -qxF "$(printf 'stray.md\tnonadopt-both\tno\tbaseline+target\trepo-ignored-only')" \
    "$GU_NA_TSV"
# Drift class K: unverified first — no ADR log, no nested Terraform, no prettier
# config and no chezmoi marker, so every seed is a real absence.
expect_ok "notes accumulate when several explanations apply" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
for na_seed in terraform/main.tf prettier.config.cjs; do
    expect_ok "unverified class-K equivalent is noted: $na_seed" \
        grep -qxF "$(printf '%s\tnonadopt-both\tno\tbaseline+target\tunverified-equivalent' \
            "$na_seed")" "$GU_NA_TSV"
done
expect_ok "the root Brewfile is a plain row in a repo that is not chezmoi-shaped" \
    grep -qxF "$(printf 'Brewfile\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
# Now supply every documented equivalent and re-run: the evidence flips.
mkdir -p "$GU_NA_REPO/docs/decisions" "$GU_NA_REPO/terraform/environments/prod"
printf '%s\n' 'renumbered' \
    >"$GU_NA_REPO/docs/decisions/0007-record-architecture-decisions.md"
printf '%s\n' 'real infra' \
    >"$GU_NA_REPO/terraform/environments/prod/main.tf"
printf '%s\n' '{}' >"$GU_NA_REPO/.prettierrc.json"
printf '%s\n' 'chezmoi' >"$GU_NA_REPO/.chezmoiroot"
printf '%s\n' 'brew bundle' >"$GU_NA_REPO/private_Brewfile"
git_commit_all "$GU_NA_REPO" "add the equivalents"
expect_ok "note fixture re-runs clean once the equivalents exist" na_classify
expect_ok "notes accumulate when the class-K evidence verifies" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; known-false-verified')" \
    "$GU_NA_TSV"
for na_seed in terraform/main.tf prettier.config.cjs; do
    expect_ok "verified class-K equivalent is noted, not filtered: $na_seed" \
        grep -qxF "$(printf '%s\tnonadopt-both\tno\tbaseline+target\tknown-false-verified' \
            "$na_seed")" "$GU_NA_TSV"
done
expect_ok "a chezmoi-shaped repo gets the contested Brewfile annotation" \
    grep -qxF "$(printf 'Brewfile\tnonadopt-both\tno\tbaseline+target\tchezmoi-managed — verify per mode-audit class K')" \
    "$GU_NA_TSV"
# Near-misses: a flat terraform root is the seed layout itself, `.terraform` is
# generated cache, an unrelated numbered ADR is not a re-recorded decision, and a
# `private_Brewfile` without a marker is just a filename.
rm -rf "$GU_NA_REPO/terraform/environments"
printf '%s\n' 'flat' >"$GU_NA_REPO/terraform/other.tf"
mkdir -p "$GU_NA_REPO/terraform/.terraform/modules/vpc"
printf '%s\n' 'vendored' \
    >"$GU_NA_REPO/terraform/.terraform/modules/vpc/main.tf"
rm -f "$GU_NA_REPO/.chezmoiroot" "$GU_NA_REPO/.prettierrc.json" \
    "$GU_NA_REPO/docs/decisions/0007-record-architecture-decisions.md"
printf '%s\n' 'unrelated decision' \
    >"$GU_NA_REPO/docs/decisions/0002-use-postgres.md"
git_commit_all "$GU_NA_REPO" "near misses only"
expect_ok "note fixture re-runs clean on the negative controls" na_classify
expect_ok "a flat terraform root does not verify the nested-layout equivalent" \
    grep -qxF "$(printf 'terraform/main.tf\tnonadopt-both\tno\tbaseline+target\tunverified-equivalent')" \
    "$GU_NA_TSV"
expect_ok "private_Brewfile without a chezmoi marker earns no annotation" \
    grep -qxF "$(printf 'Brewfile\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
expect_ok "an unrelated numbered ADR does not verify the seed ADR" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
printf '%s\n' '# Decisions' >"$GU_NA_REPO/docs/decisions/index.md"
git_commit_all "$GU_NA_REPO" "index-backed log"
expect_ok "note fixture re-runs clean with an index-backed ADR log" na_classify
expect_ok "an index-backed numbered ADR log is recorded as verified" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; known-false-verified')" \
    "$GU_NA_TSV"
rm -f "$GU_NA_REPO/docs/decisions/0002-use-postgres.md"
git_commit_all "$GU_NA_REPO" "empty index"
expect_ok "note fixture re-runs clean with an empty ADR index (index.md)" na_classify
expect_ok "an index.md with no numbered ADR does not verify the seed ADR" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
printf '%s\n' '# Notes' >"$GU_NA_REPO/docs/decisions/2-notes.md"
git_commit_all "$GU_NA_REPO" "index with non-ADR notes only"
expect_ok "note fixture re-runs clean with an index and lone 2-notes.md" na_classify
expect_ok "a lone 2-notes.md does not count as an update-mode ADR log" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
rm -f "$GU_NA_REPO/docs/decisions/2-notes.md"
rm -f "$GU_NA_REPO/docs/decisions/index.md"
printf '%s\n' 'unrelated decision' \
    >"$GU_NA_REPO/docs/decisions/0002-use-postgres.md"
printf '%s\n' '# Decisions' >"$GU_NA_REPO/docs/decisions/README.md"
git_commit_all "$GU_NA_REPO" "README-backed log"
expect_ok "note fixture re-runs clean with a README-backed ADR log" na_classify
expect_ok "a README-backed numbered ADR log is recorded as verified" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; known-false-verified')" \
    "$GU_NA_TSV"
# This is a date-named TEMPLATE seed, not merely a date-named replacement log.
# Its row exercises nonadoption_known_false_note's seed-path case arm.
expect_ok "a date-named seed gets the verified README-backed ADR log note" \
    grep -qxF "$(printf 'docs/decisions/2026-10-06-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; known-false-verified')" \
    "$GU_NA_TSV"
rm -f "$GU_NA_REPO/docs/decisions/0002-use-postgres.md"
git_commit_all "$GU_NA_REPO" "empty README index"
expect_ok "note fixture re-runs clean with an empty ADR index (README.md)" na_classify
expect_ok "a README with no numbered ADR does not verify the seed ADR" \
    grep -qxF "$(printf 'docs/decisions/0001-record-architecture-decisions.md\tnonadopt-both\tno\tbaseline+target\tco-owned-prose; unverified-equivalent')" \
    "$GU_NA_TSV"
# The prettier key is PARSED: a devDependency is not a config.
printf '%s\n' '{"name":"notes","devDependencies":{"prettier":"^3.3.0"}}' \
    >"$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "prettier devDependency"
expect_ok "note fixture re-runs clean with prettier as a devDependency" na_classify
expect_ok "a prettier devDependency is not a prettier config" \
    grep -qxF "$(printf 'prettier.config.cjs\tnonadopt-both\tno\tbaseline+target\tunverified-equivalent')" \
    "$GU_NA_TSV"
printf '%s\n' '{"name":"notes","prettier":{"semi":false}}' \
    >"$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "prettier key"
expect_ok "note fixture re-runs clean with a package.json prettier key" na_classify
expect_ok "a package.json prettier key is recorded as verified evidence" \
    grep -qxF "$(printf 'prettier.config.cjs\tnonadopt-both\tno\tbaseline+target\tknown-false-verified')" \
    "$GU_NA_TSV"
# Advisory, unlike the ignore probes: a malformed package.json must not abort a
# guarded run that is otherwise fine.
printf '%s\n' '{"name":"notes",,,' >"$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "malformed package.json"
expect_ok "a malformed package.json does not abort the classifier" na_classify
expect_ok "an unparseable package.json verifies nothing and says so" \
    grep -qxF "$(printf 'prettier.config.cjs\tnonadopt-both\tno\tbaseline+target\tpackage-json-unparseable; unverified-equivalent')" \
    "$GU_NA_TSV"
rm -f "$GU_NA_REPO/package.json"
git_commit_all "$GU_NA_REPO" "drop package.json"
# The render-side evaluator must answer for the TEMPLATE, never for this machine.
printf '%s\n' 'AGENTS.md' >"$GU_NA_ROOT/machine-excludes"
expect_ok "note fixture re-runs clean under a hostile machine excludesFile" \
    env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile \
    "GIT_CONFIG_VALUE_0=$GU_NA_ROOT/machine-excludes" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$5" HARMON_INIT_SOURCE="https://example.invalid/notes" \
        GUARDED_COPIER_CACHE="$6" HARMON_INIT_COMMIT="$7" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$4" >/dev/null' sh \
    "$GU_NA_REPO" "$GU_NA_BASE" "$GU_NA_TGT" "$GU_NONADOPT_RUNNER" \
    "$GU_NA_TPL" "$GU_NA_CACHE" "$GU_NA_TPL_COMMIT"
expect_ok "the operator's own ignore file grants no template declaration" \
    grep -qxF "$(printf 'AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$GU_NA_TSV"
# A DIRECTORY where the render ships a file used to be a note on a row, which
# let the guarded run continue into a real apply that copier aborts on. The
# rehearsal hits it first and stops the run before the worktree is touched —
# strictly better than annotating it, and one more behaviour nobody had to model.
mkdir -p "$GU_NA_REPO/AGENTS.md"
printf '%s\n' 'not the agents file' >"$GU_NA_REPO/AGENTS.md/NOTICE.txt"
git_commit_all "$GU_NA_REPO" "a directory where a file belongs"
# The classifier RETAINS the scratch on a diagnostic exit deliberately — when the
# apply fails, that half-applied tree and copier's own output are the diagnosis,
# and the error message names its location. So this fixture must clean up after
# itself, and it does so by owning the directory rather than by identifying which
# entries in the shared tmpdir are "its". The earlier shape diffed the system
# tmpdir before and after and `rm -rf`'d anything new — which on a machine
# running a second guarded update would have deleted that run's scratch out from
# under it.
NA_REFUSAL_TMP="$TMPROOT/dir-refusal-tmp"
mkdir -p "$NA_REFUSAL_TMP"
NA_REFUSAL_TMP="$(cd "$NA_REFUSAL_TMP" && pwd -P)"
na_classify_private_tmp() {
    (
        TMPDIR="$NA_REFUSAL_TMP"
        export TMPDIR
        na_classify
    )
}
expect_fail "the rehearsal refuses a directory at a rendered file's path" \
    na_classify_private_tmp
expect_ok "the refused rehearsal left its scratch behind for inspection" \
    sh -c 'test -n "$(ls -A "$1")"' sh "$NA_REFUSAL_TMP"
rm -rf "$NA_REFUSAL_TMP"
expect_fail "the fixture's private scratch directory is gone" \
    test -e "$NA_REFUSAL_TMP"
# The retention is only defensible if the operator is told where to look.
expect_ok "a failed rehearsal names the scratch it left behind" \
    sh -c 'test "$(grep -cF "inspect \$NONADOPT_SCRATCH" "$1")" -eq 2' sh \
    "$GU_NONADOPT_SNIPPET"
rm -rf "$GU_NA_REPO/AGENTS.md"
git_commit_all "$GU_NA_REPO" "remove the blocking directory"

# --- the rehearsal copies managed content only --------------------------------
# A whole-tree copy pulled in every ignored byte the repo happened to hold. This
# fixture plants an unmanaged cache beside a managed ignored path and checks
# which one reaches the scratch. `scratch-copy-paths` survives the run, so the
# copy set is directly assertable rather than inferred.
SCOPE_ROOT="$TMPROOT/rehearsal-scope"
SCOPE_TPL="$SCOPE_ROOT/template"
mkdir -p "$SCOPE_TPL/template/.vscode" "$SCOPE_ROOT/cache"
cat >"$SCOPE_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Scope
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$SCOPE_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' '{"local":true}' >"$SCOPE_TPL/template/.vscode/local.json"
printf '%s\n' 'agents' >"$SCOPE_TPL/template/AGENTS.md"
printf '%s\n' 'baseline' >"$SCOPE_TPL/template/version.txt"
printf '%s\n' '.vscode/*' 'node_modules/' >"$SCOPE_TPL/template/.gitignore"
git_init "$SCOPE_TPL"
# Render-ignored yet template-managed: force-add or the template's own
# .gitignore keeps it out of the template repo and it never renders.
git -C "$SCOPE_TPL" add -f template/.vscode/local.json
git_commit_all "$SCOPE_TPL" "scope baseline"
SCOPE_BASE_COMMIT="$(git -C "$SCOPE_TPL" rev-parse HEAD)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$SCOPE_BASE_COMMIT" \
    "$SCOPE_TPL" "$SCOPE_ROOT/repo" >/dev/null
git_init "$SCOPE_ROOT/repo"
git_commit_all "$SCOPE_ROOT/repo" "generated"
printf '%s\n' '/.copier-guarded-update/' >>"$SCOPE_ROOT/repo/.git/info/exclude"
# The unmanaged cache: ignored, present, and nothing to do with the template.
mkdir -p "$SCOPE_ROOT/repo/node_modules/pkg/deep"
for scope_n in 1 2 3 4 5; do
    printf '%s\n' "junk $scope_n" \
        >"$SCOPE_ROOT/repo/node_modules/pkg/deep/f$scope_n.js"
done
printf '%s\n' 'target' >"$SCOPE_TPL/template/version.txt"
git_commit_all "$SCOPE_TPL" "scope target"
SCOPE_TGT_COMMIT="$(git -C "$SCOPE_TPL" rev-parse HEAD)"
SCOPE_STATE="$SCOPE_ROOT/repo/.copier-guarded-update"
mkdir -p "$SCOPE_STATE"
printf '{}\n' >"$SCOPE_STATE/reviewed-data.yml"
copier copy --trust --defaults --skip-tasks --vcs-ref="$SCOPE_BASE_COMMIT" \
    "$SCOPE_TPL" "$SCOPE_ROOT/base-render" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$SCOPE_TGT_COMMIT" \
    "$SCOPE_TPL" "$SCOPE_ROOT/target-render" >/dev/null
for scope_side in base target; do
    (cd "$SCOPE_ROOT/$scope_side-render" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$SCOPE_STATE/$(test "$scope_side" = base &&
            printf baseline || printf target)-managed-paths"
done
: >"$SCOPE_STATE/ignored-existing-paths"
: >"$SCOPE_STATE/ignored-absent-paths"
while IFS= read -r scope_path; do
    git -C "$SCOPE_ROOT/repo" check-ignore -q -- "$scope_path" || continue
    if test -e "$SCOPE_ROOT/repo/$scope_path"; then
        printf '%s\n' "$scope_path" >>"$SCOPE_STATE/ignored-existing-paths"
    else
        printf '%s\n' "$scope_path" >>"$SCOPE_STATE/ignored-absent-paths"
    fi
done <"$SCOPE_STATE/target-managed-paths"
expect_ok "the scope fixture really has a managed ignored path" \
    grep -qx '.vscode/local.json' "$SCOPE_STATE/ignored-existing-paths"
expect_ok "the rehearsal runs clean against a repo holding an unmanaged cache" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$4" HARMON_INIT_SOURCE="https://example.invalid/scope" \
        GUARDED_COPIER_CACHE="$5" HARMON_INIT_COMMIT="$6" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$7" >/dev/null' sh \
    "$SCOPE_ROOT/repo" "$SCOPE_ROOT/base-render" "$SCOPE_ROOT/target-render" \
    "$SCOPE_TPL" "$SCOPE_ROOT/cache" "$SCOPE_TGT_COMMIT" "$GU_NONADOPT_RUNNER"
expect_fail "the unmanaged ignored cache is not overlaid into the scratch" \
    grep -q node_modules "$SCOPE_STATE/scratch-overlay-paths"
expect_ok "the managed ignored path IS overlaid into the scratch" \
    grep -qx './.vscode/local.json' "$SCOPE_STATE/scratch-overlay-paths"
# End-to-end proof that the overlay MATTERS: without it the clone would lack the
# managed ignored file, copier would render it back, and it would surface as a
# `created` row. Its absence from the report is the overlay doing its job.
expect_fail "the overlaid ignored path is not reported as a non-adoption" \
    grep -q '.vscode/local.json' "$SCOPE_STATE/nonadoption-report.tsv"
# THE one-universe invariant. The scratch is deliberately a subset of the
# worktree, so diffing the real repo against it reported every unmanaged ignored
# file as deleted by the apply — five rows here, thousands on a real repo — and
# reconciliation then failed against a tree that still had them. Both sides of
# the diff now come from the scratch.
expect_fail "unmanaged ignored content is not reported as deleted by the apply" \
    grep -q node_modules "$SCOPE_STATE/nonadoption-report.tsv"
expect_ok "both sides of the rehearsal diff are inventoried from the scratch" \
    sh -c 'test "$(grep -c "nonadoption_inventory \"\$NONADOPT_SCRATCH/repo\"" "$1")" -eq 2 &&
        ! grep -qF "nonadoption_inventory . >" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# A before-inventory taken after the update would make every diff empty, so the
# ordering is asserted rather than assumed.
expect_ok "the before-inventory is taken before the rehearsal update" \
    sh -c 'before="$(grep -nF "apply-before-paths\" ||" "$1" | head -1 | cut -d: -f1)"
        upd="$(grep -nF "run_guarded_copier update --trust --defaults --skip-tasks" "$1" |
            head -1 | cut -d: -f1)"
        after="$(grep -nF "apply-after-paths\" ||" "$1" | head -1 | cut -d: -f1)"
        test -n "$before" && test -n "$upd" && test -n "$after" &&
        test "$before" -lt "$upd" && test "$upd" -lt "$after"' sh \
    "$GU_NONADOPT_SNIPPET"

# --- the frozen verdict is bound to the run that produced it ------------------
# "clean" on its own is a claim with no subject. Rollback deletes GUARDED_STATE
# but leaves the branch-keyed files, so a rollback-then-rerun that dies before
# persisting used to leave a clean verdict beside a report describing a tree
# nobody has any more — and §4 accepted it.
VB_DIR="$TMPROOT/verdict-binding"
mkdir -p "$VB_DIR/.copier-guarded-update"
git_init "$VB_DIR"
printf '%s\n' 'seed' >"$VB_DIR/seed.txt"
git_commit_all "$VB_DIR" "seed"
printf '%s\n' '/.copier-guarded-update/' >>"$VB_DIR/.git/info/exclude"
VB_STATE="$VB_DIR/.copier-guarded-update"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$VB_STATE/target-commit"
git -C "$VB_DIR" rev-parse HEAD >"$VB_STATE/start-head"
printf 'gone.md\tunknown-until-apply\tn/a-removed\tbaseline-only\t-\n' \
    >"$VB_STATE/nonadoption-report.tsv"
expect_ok "reconciliation records a verdict for this run" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$VB_DIR" "$GU_RECONCILE"
expect_ok "the verdict names the report it describes" \
    sh -c 'oid="$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/nonadoption-report.tsv")"
        grep -qx "report: $oid" "$1/.copier-guarded-update/nonadoption-reconciled"' sh \
    "$VB_DIR"
expect_ok "the verdict names the run's target commit and start head" \
    sh -c 'grep -qx "target-commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$1" &&
        grep -qE "^start-head: [0-9a-f]{40}$" "$1"' sh \
    "$VB_STATE/nonadoption-reconciled"
# The rollback-then-rerun shape: the report changes, the old verdict does not.
# A word-only check passes here; the binding does not.
printf 'other.md\tnonadopt-both\tno\tbaseline+target\t-\n' \
    >"$VB_STATE/nonadoption-report.tsv"
expect_ok "a stale verdict still says clean — which is why the word is not enough" \
    grep -qx 'reconciled: clean' "$VB_STATE/nonadoption-reconciled"
expect_fail "a stale verdict no longer matches the report beside it" \
    sh -c 'oid="$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/nonadoption-report.tsv")"
        grep -qx "report: $oid" "$1/.copier-guarded-update/nonadoption-reconciled"' sh \
    "$VB_DIR"
# §1 clears both branch-keyed files on entry, so the rerun cannot inherit them.
expect_ok "section 1 clears this branch's stale report and verdict on entry" \
    sh -c 'grep -qF "guarded-update-nonadoption guarded-update-reconciled" "$1" &&
        grep -qF "NONADOPT_STALE_FILE" "$1" &&
        grep -qF "rm -f -- \"\$NONADOPT_STALE_FILE\"" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"
# EXECUTED, not grepped. §4's verification was inline bash in a fenced block with
# no extraction handle, so every assertion about it was a `grep` over the prose —
# which is exactly how it shipped hashing a variable that no longer existed in
# that scope. It is a function now, for the same reason `nonadoption_reconcile`
# is one: a recipe a test cannot run is a recipe nothing checks.
GU_VERIFY="$TMPROOT/nonadoption-verify-verdict.sh"
{
    printf '%s\n' 'set -eu'
    sed -n '/^nonadoption_verify_verdict() {/,/^}$/p' \
        "$UPDATE_PROCEDURE"
    printf '%s\n' 'nonadoption_verify_verdict'
} >"$GU_VERIFY"
expect_ok "the verdict verification is extractable from the guidance" \
    sh -c 'grep -qF "nonadoption_verify_verdict() {" "$1" &&
        grep -qF "VERIFY_REPORT_OID" "$1"' sh "$GU_VERIFY"
VV_DIR="$TMPROOT/verdict-verification"
mkdir -p "$VV_DIR"
git_init "$VV_DIR"
printf '%s\n' 'seed' >"$VV_DIR/seed.txt"
git_commit_all "$VV_DIR" "seed"
VV_COMMIT=cccccccccccccccccccccccccccccccccccccccc
VV_OLD_COMMIT=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
vv_write_answers() {
    printf '_commit: %s\n_src_path: https://example.invalid/vv\n' "$1" \
        >"$VV_DIR/.copier-answers.yml"
}
vv_paths() {
    VV_BR="$(git -C "$VV_DIR" branch --show-current)"
    VV_REPORT="$VV_DIR/.git/guarded-update-nonadoption/$VV_BR"
    VV_VERDICT="$VV_DIR/.git/guarded-update-reconciled/$VV_BR"
    mkdir -p "$(dirname "$VV_REPORT")" "$(dirname "$VV_VERDICT")"
}
vv_paths
vv_write_clean() {
    printf 'p\tnonadopt-both\tno\tbaseline+target\t-\n' >"$VV_REPORT"
    {
        printf 'reconciled: clean\n'
        printf 'report: %s\n' "$(git -C "$VV_DIR" hash-object "$VV_REPORT")"
        printf 'target-commit: %s\n' "$VV_COMMIT"
        printf 'start-head: %s\n' "$(git -C "$VV_DIR" rev-parse HEAD)"
    } >"$VV_VERDICT"
}
vv_write_clean_run() {
    vv_write_clean
    vv_write_answers "$VV_COMMIT"
}
# No HARMON_INIT_COMMIT in the environment at all: the verification must read the
# lineage the tree actually carries, and passing the variable would let a broken
# implementation keep passing on the intent instead of the fact.
vv_run() {
    (cd "$VV_DIR" && bash -eu "$GU_VERIFY")
}
# The clean path has to pass, or every refusal below proves nothing. This is the
# assertion that would have caught the unset variable: under `bash -eu` it aborts
# before reaching any check.
vv_write_clean_run
expect_ok "verdict verification accepts a bound, clean, current verdict" vv_run
# ...and each way it must refuse.
mv "$VV_VERDICT" "$VV_VERDICT.away"
expect_fail "verdict verification refuses a missing verdict" vv_run
mv "$VV_VERDICT.away" "$VV_VERDICT"
printf 'reconciled: clean\n' >"$VV_VERDICT"
expect_fail "verdict verification refuses a verdict with no binding" vv_run
vv_write_clean_run
printf 'q\tnonadopt-both\tno\tbaseline+target\t-\n' >"$VV_REPORT"
expect_fail "verdict verification refuses a verdict describing another report" vv_run
# THE lineage case. Reverting `.copier-answers.yml` to the pre-update baseline —
# what §3's manual reconciliation or a `git restore` does — leaves a tree at the
# old version beside a verdict describing the new one. Comparing the verdict to
# the session's own `$HARMON_INIT_COMMIT` passed happily; comparing it to the
# lineage the tree carries does not.
vv_write_clean_run
vv_write_answers "$VV_OLD_COMMIT"
expect_fail "verdict verification refuses a verdict when the answers file was reverted" \
    vv_run
vv_write_clean_run
printf '_src_path: https://example.invalid/vv\n' >"$VV_DIR/.copier-answers.yml"
expect_fail "verdict verification refuses an answers file recording no _commit" \
    vv_run
# A content-only update — every managed path present, only bytes changed —
# legitimately reports nothing. That is a successful run, and refusing it on size
# blocked hand-off on exactly the update that went best. Staleness is caught by
# the hash and lineage binding, not by emptiness.
vv_write_answers "$VV_COMMIT"
: >"$VV_REPORT"
{
    printf 'reconciled: clean\n'
    printf 'report: %s\n' "$(git -C "$VV_DIR" hash-object "$VV_REPORT")"
    printf 'target-commit: %s\n' "$VV_COMMIT"
    printf 'start-head: %s\n' "$(git -C "$VV_DIR" rev-parse HEAD)"
} >"$VV_VERDICT"
expect_ok "verdict verification accepts an empty report with a matching verdict" \
    vv_run
# ...and an empty report still has to be the one the verdict describes.
printf 'x\tnonadopt-both\tno\tbaseline+target\t-\n' >"$VV_REPORT"
expect_fail "an empty verdict binding does not excuse a non-empty report" vv_run
# Missing entirely is a different fact from empty, and still a refusal.
vv_write_clean_run
rm -f "$VV_REPORT"
expect_fail "verdict verification refuses a missing persisted report" vv_run
vv_write_clean_run
expect_ok "the verification tests for existence, not size" \
    sh -c 'grep -qF "test -f \"\$VERIFY_REPORT\"" "$1" &&
        ! grep -qF "test -s \"\$VERIFY_REPORT\"" "$1"' sh "$GU_VERIFY"
expect_ok "the verification reads the lineage rather than the session variable" \
    sh -c 'grep -qF "yq -r '\''._commit // \"\"'\'' .copier-answers.yml" "$1" &&
        ! grep -qE "^[^#]*target-commit: \\\$HARMON_INIT_COMMIT" "$1"' sh \
    "$GU_VERIFY"

# --- conflict artefacts are not adoptions -------------------------------------
# A `.rej`/`.orig` copier leaves behind is created by the apply but shipped by
# neither render. Labelling it `new-in-target` filed a merge failure in the
# adoption table.
ART_DIR="$TMPROOT/apply-artifact"
mkdir -p "$ART_DIR/.copier-guarded-update"
git_init "$ART_DIR"
printf '%s\n' 'seed' >"$ART_DIR/seed.txt"
git_commit_all "$ART_DIR" "seed"
printf '%s\n' '/.copier-guarded-update/' >>"$ART_DIR/.git/info/exclude"
ART_STATE="$ART_DIR/.copier-guarded-update"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$ART_STATE/target-commit"
git -C "$ART_DIR" rev-parse HEAD >"$ART_STATE/start-head"
printf '%s\n' 'present' >"$ART_DIR/conf.md.rej"
printf 'conf.md.rej\tunknown-until-apply\tn/a-unrendered\tunrendered\t-\n' \
    >"$ART_STATE/nonadoption-report.tsv"
expect_ok "reconciliation resolves an unrendered created path" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$ART_DIR" "$GU_RECONCILE"
expect_ok "a path neither render ships is noted as an apply artefact" \
    grep -qxF "$(printf 'conf.md.rej\tcreated\tn/a-unrendered\tunrendered\tapply-artifact')" \
    "$ART_STATE/nonadoption-report.tsv"
expect_ok "the hand-off routes apply artefacts to the anomalies, not the table" \
    sh -c 'grep -qF "noted \`apply-artifact\`" "$1" &&
        grep -qF "never let it reach the table" "$1"' sh \
    "$UPDATE_PROCEDURE"
expect_ok "the classifier derives the created note from target membership" \
    sh -c 'grep -qF "if test \"\$NONADOPT_IN_TARGET\" -eq 0; then" "$1" &&
        grep -qF "nonadoption_add_note apply-artifact" "$1"' sh \
    "$GU_NONADOPT_SNIPPET"

# --- the degraded path resolves with class-appropriate before/after -----------
# Exercised as a unit on the reconciliation recipe: a real `_migrations` update
# cannot produce a surviving baseline-only file on demand, and the label logic is
# what is under test. Reading present-after alone called a surviving
# baseline-only file `created` and a removed one `nonadopt-both`, both backwards.
DEG_DIR="$TMPROOT/degraded-resolution"
mkdir -p "$DEG_DIR/.copier-guarded-update"
for deg_present in keep.md made.md newf.md; do
    printf '%s\n' 'present' >"$DEG_DIR/$deg_present"
done
# §1 records the before-state as a `present-before` note, because reconciliation
# runs after the tree has moved and has no other way to recover it. Membership
# used to be read as a proxy — `baseline-only` implying present — which was only
# true while the degraded branch skipped present paths the target still ships.
# It no longer does, so the note is the contract.
{
    printf 'keep.md\tunknown-until-apply\tn/a-removed\tbaseline-only\tpresent-before\n'
    printf 'gone.md\tunknown-until-apply\tn/a-removed\tbaseline-only\tpresent-before\n'
    printf 'eaten.md\tunknown-until-apply\tno\tbaseline+target\tpresent-before\n'
    printf 'made.md\tunknown-until-apply\tno\tbaseline+target\t-\n'
    printf 'newf.md\tunknown-until-apply\tn/a-new\ttarget-only\tco-owned-prose\n'
    printf 'never.md\tunknown-until-apply\tno\tbaseline+target\t-\n'
} >"$DEG_DIR/.copier-guarded-update/nonadoption-report.tsv"
DEG_TSV="$DEG_DIR/.copier-guarded-update/nonadoption-report.tsv"
expect_ok "reconciliation resolves a degraded report cleanly" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$DEG_DIR" "$GU_RECONCILE"
# Present before AND after is not a transition; the rehearsed path emits no row
# for it, so the resolution must not invent one.
expect_fail "a surviving present file yields no row" \
    grep -q '^keep\.md' "$DEG_TSV"
expect_ok "a removed baseline-only file resolves to deleted" \
    grep -qxF "$(printf 'gone.md\tdeleted\tn/a-removed\tbaseline-only\tpresent-before')" \
    "$DEG_TSV"
# THE degraded gap. A path the repo had and the target still ships was skipped
# entirely, on the reasoning that an ordinary apply leaves it alone — but this
# branch exists BECAUSE migrations run arbitrary commands, and one can delete it.
# The row exists now, and its disappearance is flagged as a question.
expect_ok "a present in-target file the apply removed resolves to deleted" \
    grep -qxF "$(printf 'eaten.md\tdeleted\tno\tbaseline+target\tpresent-before; migration-effect?')" \
    "$DEG_TSV"
expect_ok "the degraded branch records the before-state it observed" \
    sh -c 'grep -qF "nonadoption_add_note present-before" "$1" &&
        grep -qF "*present-before*)" "$2"' sh \
    "$GU_NONADOPT_SNIPPET" "$GU_RECONCILE"
expect_ok "a both-renders file the apply wrote resolves to created/recreated" \
    grep -qxF "$(printf 'made.md\tcreated\tno\tbaseline+target\trecreated')" \
    "$DEG_TSV"
expect_ok "a target-only file the apply wrote keeps its evidence in order" \
    grep -qxF "$(printf 'newf.md\tcreated\tn/a-new\ttarget-only\tnew-in-target; co-owned-prose')" \
    "$DEG_TSV"
expect_ok "a file the apply never wrote resolves to nonadopt-both" \
    grep -qxF "$(printf 'never.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$DEG_TSV"

# --- the rehearsal must not touch the repo it rehearses on --------------------
# A LINKED worktree's `.git` is a POINTER FILE. Copying it verbatim leaves the
# scratch resolving to the real worktree's admin dir, and copier runs
# `git write-tree` in the subproject during update — so the rehearsal would stage
# into the very tree it exists to observe from a distance. This repo is itself
# developed in linked worktrees, so the hazard is the normal case, not a corner.
ISO_ROOT="$TMPROOT/rehearsal-isolation"
ISO_TPL="$ISO_ROOT/template"
mkdir -p "$ISO_TPL/template" "$ISO_ROOT/cache"
cat >"$ISO_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
project_name:
  type: str
  default: Iso
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$ISO_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' 'agents' >"$ISO_TPL/template/AGENTS.md"
printf '%s\n' 'baseline' >"$ISO_TPL/template/version.txt"
git_init "$ISO_TPL"
git_commit_all "$ISO_TPL" "iso baseline"
ISO_BASE_COMMIT="$(git -C "$ISO_TPL" rev-parse HEAD)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$ISO_BASE_COMMIT" \
    "$ISO_TPL" "$ISO_ROOT/main" >/dev/null
git_init "$ISO_ROOT/main"
git_commit_all "$ISO_ROOT/main" "generated"
printf '%s\n' 'target' >"$ISO_TPL/template/version.txt"
git_commit_all "$ISO_TPL" "iso target"
ISO_TGT_COMMIT="$(git -C "$ISO_TPL" rev-parse HEAD)"
# The subject: a LINKED worktree, whose .git is a pointer file.
git -C "$ISO_ROOT/main" worktree add -q "$ISO_ROOT/wt" -b feat/rehearse >/dev/null
expect_ok "the isolation fixture really is a linked worktree" \
    test -f "$ISO_ROOT/wt/.git"
rm "$ISO_ROOT/wt/AGENTS.md"
git_commit_all "$ISO_ROOT/wt" "decline AGENTS.md"
ISO_STATE="$ISO_ROOT/wt/.copier-guarded-update"
mkdir -p "$ISO_STATE"
printf '{}\n' >"$ISO_STATE/reviewed-data.yml"
printf '%s\n' '/.copier-guarded-update/' \
    >>"$(git -C "$ISO_ROOT/wt" rev-parse --git-path info/exclude)"
copier copy --trust --defaults --skip-tasks --vcs-ref="$ISO_BASE_COMMIT" \
    "$ISO_TPL" "$ISO_ROOT/base-render" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$ISO_TGT_COMMIT" \
    "$ISO_TPL" "$ISO_ROOT/target-render" >/dev/null
for iso_side in base target; do
    (cd "$ISO_ROOT/$iso_side-render" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$ISO_STATE/$(test "$iso_side" = base &&
            printf baseline || printf target)-managed-paths"
done
: >"$ISO_STATE/ignored-absent-paths"
: >"$ISO_STATE/ignored-existing-paths"
ISO_INDEX="$(git -C "$ISO_ROOT/wt" rev-parse --git-path index)"
ISO_INDEX_BEFORE="$(git hash-object "$ISO_INDEX")"
expect_ok "the rehearsal runs clean from inside a linked worktree" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$4" HARMON_INIT_SOURCE="https://example.invalid/iso" \
        GUARDED_COPIER_CACHE="$5" HARMON_INIT_COMMIT="$6" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$7" >/dev/null' sh \
    "$ISO_ROOT/wt" "$ISO_ROOT/base-render" "$ISO_ROOT/target-render" \
    "$ISO_TPL" "$ISO_ROOT/cache" "$ISO_TGT_COMMIT" "$GU_NONADOPT_RUNNER"
# THE isolation assertions. At 4c4a84b the pointer-file copy made `git add` in
# the scratch write straight through to this index.
expect_ok "the real worktree's index is untouched by the rehearsal" \
    sh -c 'test "$(git hash-object "$1")" = "$2"' sh \
    "$ISO_INDEX" "$ISO_INDEX_BEFORE"
expect_ok "the real worktree's status is untouched by the rehearsal" \
    sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$ISO_ROOT/wt"
expect_ok "the rehearsal still observed the declined path from a linked worktree" \
    grep -qxF "$(printf 'AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-')" \
    "$ISO_STATE/nonadoption-report.tsv"
# The three index properties the hand-built construction each failed on in turn,
# now free with the clone. Asserted on a clone of this very worktree rather than
# on the classifier, because it is `git clone` that is being trusted.
ISO_PROBE="$ISO_ROOT/clone-probe"
printf '%s\n' 'tracked yet ignored' >"$ISO_ROOT/wt/tracked-ignored.txt"
printf '%s\n' 'x' >"$ISO_ROOT/wt/--checkpoint=exec,date"
printf '%s\n' 'tracked-ignored.txt' 'cache/' >"$ISO_ROOT/wt/.gitignore"
mkdir -p "$ISO_ROOT/wt/cache"
printf '%s\n' 'junk' >"$ISO_ROOT/wt/cache/j.txt"
git -C "$ISO_ROOT/wt" add -A >/dev/null
git -C "$ISO_ROOT/wt" add -f tracked-ignored.txt './--checkpoint=exec,date' >/dev/null
git_commit_all "$ISO_ROOT/wt" "awkward index entries"
expect_ok "cloning a linked worktree reproduces its branch and index" \
    sh -c 'cd "$1" && git clone --no-hardlinks --quiet . "$2"' sh \
    "$ISO_ROOT/wt" "$ISO_PROBE"
expect_ok "the clone checks out the linked worktree's own branch" \
    sh -c 'test "$(git -C "$1" symbolic-ref --short HEAD)" = feat/rehearse' sh \
    "$ISO_PROBE"
# Round-2 P1: `git add -A` in a fresh repo drops tracked-but-ignored files, so
# copier read them as deleted. A clone keeps them in the index.
expect_ok "a tracked-but-ignored file stays in the cloned index" \
    sh -c 'test -n "$(git -C "$1" ls-files tracked-ignored.txt)"' sh "$ISO_PROBE"
# Round-3 P1: a filename that looks like a tar option was passed through a `-T`
# list. There is no path list any more, and the name survives as data.
expect_ok "an option-shaped filename survives as data, not as a flag" \
    sh -c 'test -f "$1/--checkpoint=exec,date"' sh "$ISO_PROBE"
# Untracked ignored content is NOT in the clone — which is the point of the
# managed-only overlay.
expect_fail "unmanaged ignored content is absent from the clone" \
    test -e "$ISO_PROBE/cache/j.txt"

# --- `_migrations` are NOT covered by `--skip-tasks` --------------------------
# Verified against copier 9.17.1: `_execute_tasks(self.template.tasks)` is
# guarded by `skip_tasks`, `migration_tasks("before"/"after")` is not. A
# rehearsal would therefore run migrations a second time, against a copy, with
# the real run still to come — so the rehearsal is refused instead.
MIG_ROOT="$TMPROOT/rehearsal-migrations"
MIG_TPL="$MIG_ROOT/template"
mkdir -p "$MIG_TPL/template" "$MIG_ROOT/cache"
cat >"$MIG_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_migrations:
  - command: ["sh", "-c", "echo ran >> migration-sentinel.txt"]
_tasks:
  - ["sh", "-c", "echo ran >> task-sentinel.txt"]
project_name:
  type: str
  default: Mig
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$MIG_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' 'agents' >"$MIG_TPL/template/AGENTS.md"
printf '%s\n' 'baseline' >"$MIG_TPL/template/version.txt"
git_init "$MIG_TPL"
git_commit_all "$MIG_TPL" "mig baseline"
MIG_BASE_COMMIT="$(git -C "$MIG_TPL" rev-parse HEAD)"
git -C "$MIG_TPL" tag v1.0.0
copier copy --trust --defaults --skip-tasks --vcs-ref=v1.0.0 \
    "$MIG_TPL" "$MIG_ROOT/repo" >/dev/null
git_init "$MIG_ROOT/repo"
git_commit_all "$MIG_ROOT/repo" "generated"
printf '%s\n' 'target' >"$MIG_TPL/template/version.txt"
git_commit_all "$MIG_TPL" "mig target"
git -C "$MIG_TPL" tag v2.0.0
MIG_TGT_COMMIT="$(git -C "$MIG_TPL" rev-parse HEAD)"
# The behavioural fact the guard exists for, proved directly on a throwaway copy.
cp -a "$MIG_ROOT/repo" "$MIG_ROOT/probe"
expect_ok "the migration probe update succeeds" \
    sh -c 'cd "$1" && copier update --trust --defaults --skip-tasks \
        --vcs-ref=v2.0.0 >/dev/null 2>&1' sh "$MIG_ROOT/probe"
expect_ok "_migrations RUN despite --skip-tasks" \
    test -e "$MIG_ROOT/probe/migration-sentinel.txt"
expect_fail "_tasks are correctly suppressed by --skip-tasks" \
    test -e "$MIG_ROOT/probe/task-sentinel.txt"
# ...so the classifier must refuse to rehearse.
rm "$MIG_ROOT/repo/AGENTS.md"
git_commit_all "$MIG_ROOT/repo" "decline AGENTS.md"
MIG_STATE="$MIG_ROOT/repo/.copier-guarded-update"
mkdir -p "$MIG_STATE"
printf '{}\n' >"$MIG_STATE/reviewed-data.yml"
printf '%s\n' '/.copier-guarded-update/' >>"$MIG_ROOT/repo/.git/info/exclude"
copier copy --trust --defaults --skip-tasks --vcs-ref="$MIG_BASE_COMMIT" \
    "$MIG_TPL" "$MIG_ROOT/base-render" >/dev/null
copier copy --trust --defaults --skip-tasks --vcs-ref="$MIG_TGT_COMMIT" \
    "$MIG_TPL" "$MIG_ROOT/target-render" >/dev/null
for mig_side in base target; do
    (cd "$MIG_ROOT/$mig_side-render" && find . \( -type f -o -type l \) -print) |
        sed 's#^\./##' | LC_ALL=C sort -u \
        >"$MIG_STATE/$(test "$mig_side" = base &&
            printf baseline || printf target)-managed-paths"
done
: >"$MIG_STATE/ignored-absent-paths"
: >"$MIG_STATE/ignored-existing-paths"
expect_ok "the classifier degrades cleanly when the target declares _migrations" \
    sh -c 'cd "$1" && GUARDED_STATE=.copier-guarded-update \
        BASELINE_DISCOVERY="$2" TARGET_DISCOVERY="$3" \
        GUARDED_TEMPLATE="$4" HARMON_INIT_SOURCE="https://example.invalid/mig" \
        GUARDED_COPIER_CACHE="$5" HARMON_INIT_COMMIT="$6" \
        REVIEWED_DATA=".copier-guarded-update/reviewed-data.yml" \
        bash -eu "$7" >/dev/null 2>&1' sh \
    "$MIG_ROOT/repo" "$MIG_ROOT/base-render" "$MIG_ROOT/target-render" \
    "$MIG_TPL" "$MIG_ROOT/cache" "$MIG_TGT_COMMIT" "$GU_NONADOPT_RUNNER"
expect_ok "a migrations target yields unknown-until-apply rows" \
    grep -qxF "$(printf 'AGENTS.md\tunknown-until-apply\tno\tbaseline+target\t-')" \
    "$MIG_STATE/nonadoption-report.tsv"
# The whole point: no migration fired in the repo the classifier ran against.
expect_fail "the refused rehearsal ran no migration" \
    test -e "$MIG_ROOT/repo/migration-sentinel.txt"
# And §2's reconciliation resolves those rows against the real apply.
expect_ok "the real update applies and runs its migration exactly once" \
    sh -c 'cd "$1" && copier update --trust --defaults \
        --vcs-ref="$2" >/dev/null 2>&1' sh "$MIG_ROOT/repo" "$MIG_TGT_COMMIT"
expect_ok "reconciliation resolves unknown-until-apply against the real result" \
    sh -c 'cd "$1" && bash -eu "$2" &&
        grep -qxF "$(printf "AGENTS.md\tnonadopt-both\tno\tbaseline+target\t-")" \
            .copier-guarded-update/nonadoption-report.tsv' sh \
    "$MIG_ROOT/repo" "$GU_RECONCILE"

# --- `_skip_if_exists` recreates an absent path: the load-bearing proof --------
# Every `recreate-expected` claim above rests on one fact about copier that no
# amount of reading the classifier can establish: that `_skip_if_exists` on an
# ABSENT path renders it fresh rather than preserving the absence. If that were
# false the whole class would be wrong in the most dangerous direction — telling
# an operator that CODEOWNERS stays gone while the update quietly reinstates it.
# So it is proved against real copier, as a controlled A/B: two files identical
# in every respect that matters (shipped by both renders, byte-identical across
# the range, deleted from the repo in the same commit) differing only in whether
# `_skip_if_exists` covers them. Its own fixture, because a directory-free
# minimal template is far cheaper to reason about than perturbing the guarded
# fixture above — and because a `_skip_if_exists` file added there would ride
# through its rollback and hash assertions.
SKIP_ROOT="$TMPROOT/skip-if-exists"
SKIP_TPL="$SKIP_ROOT/template"
SKIP_PROJ="$SKIP_ROOT/project"
mkdir -p "$SKIP_TPL/template/.github"
cat >"$SKIP_TPL/copier.yml" <<'EOF'
_min_copier_version: "9.4.0"
_subdirectory: template
_skip_if_exists:
  - .github/CODEOWNERS
  - "*.code-workspace"
project_name:
  type: str
  default: Skip
EOF
printf '%s\n' '{{ _copier_answers|to_nice_yaml -}}' \
    >"$SKIP_TPL/template/.copier-answers.yml.jinja"
printf '%s\n' '* @owner' >"$SKIP_TPL/template/.github/CODEOWNERS"
printf '%s\n' 'peacock' >"$SKIP_TPL/template/proj.code-workspace"
# The control: same shape, NOT covered by _skip_if_exists.
printf '%s\n' 'shared' >"$SKIP_TPL/template/shared-note.md"
# The mechanism control. Same shape as shared-note.md, except its CONTENT changes
# across the range — so a diff-driven merge would have a real hunk and no file to
# apply it to, and would conflict or recreate. Copier does neither, which is what
# distinguishes "excluded from creation" from "the diff happened to be empty".
printf '%s\n' 'v1 content' 'line two' >"$SKIP_TPL/template/changed-note.md"
printf '%s\n' 'baseline' >"$SKIP_TPL/template/version.txt"
git_init "$SKIP_TPL"
git_commit_all "$SKIP_TPL" "skip baseline"
git -C "$SKIP_TPL" tag v1.0.0
copier copy --trust --defaults --vcs-ref=v1.0.0 \
    "$SKIP_TPL" "$SKIP_PROJ" >/dev/null
# Copier 9.16 compares the update destination lexically with a resolved
# repository top. Canonicalize this macOS mktemp-derived path so /var and
# /private/var aliases cannot make the fixture crash (harmon-init#847).
SKIP_PROJ="$(cd "$SKIP_PROJ" && pwd -P)"
git_init "$SKIP_PROJ"
git_commit_all "$SKIP_PROJ" "generated"
rm "$SKIP_PROJ/.github/CODEOWNERS" "$SKIP_PROJ/proj.code-workspace" \
    "$SKIP_PROJ/shared-note.md" "$SKIP_PROJ/changed-note.md"
git_commit_all "$SKIP_PROJ" "decline all three"
expect_fail "skip-if-exists fixture starts with the declined paths absent" \
    test -e "$SKIP_PROJ/.github/CODEOWNERS"
# Only version.txt moves across the range; the three declined files are
# byte-identical in both renders, so nothing about THEM is in the applied diff.
printf '%s\n' 'target' >"$SKIP_TPL/template/version.txt"
printf '%s\n' 'v2 content' 'line two rewritten' 'line three' \
    >"$SKIP_TPL/template/changed-note.md"
git_commit_all "$SKIP_TPL" "skip target"
git -C "$SKIP_TPL" tag v2.0.0
expect_ok "skip-if-exists fixture updates cleanly to the target" \
    copier update --trust --defaults --vcs-ref=v2.0.0 "$SKIP_PROJ"
expect_ok "the update applied the target content" \
    grep -qxF target "$SKIP_PROJ/version.txt"
expect_ok "_skip_if_exists RECREATES an absent literal path" \
    test -e "$SKIP_PROJ/.github/CODEOWNERS"
expect_ok "_skip_if_exists RECREATES an absent globbed path" \
    test -e "$SKIP_PROJ/proj.code-workspace"
# The control, in the same update: this is what "permanent" actually looks like.
expect_fail "an ordinary both-renders absence stays absent in the same update" \
    test -e "$SKIP_PROJ/shared-note.md"
# The mechanism control. changed-note.md is byte-DIFFERENT between the two
# renders, so "both renders ship it, therefore the diff is empty" does not apply
# to it — and it still stays gone. Copier excluded it from creation because the
# repo deleted it, full stop. A diff-driven apply would have produced a conflict
# or recreated the file; neither happens, and no reject artifact is written.
expect_fail "a deleted path stays absent even when its content changed in range" \
    test -e "$SKIP_PROJ/changed-note.md"
expect_ok "the changed-in-range exclusion leaves no conflict artifacts" \
    sh -c 'test -z "$(find "$1" -name "*.rej" -o -name "*.orig")"' sh "$SKIP_PROJ"
# It comes back with the TARGET render's content, and untracked — which is why §4
# tells the operator to read it rather than assume their old version returned.
expect_ok "the recreated file carries the render's content, not the repo's" \
    grep -qxF '* @owner' "$SKIP_PROJ/.github/CODEOWNERS"
# shell-robustness: begin-exempt — the pipeline runs in a `sh -c`/`bash -c` subshell that never enables pipefail
expect_ok "the recreated file arrives untracked" \
    sh -c 'git -C "$1" status --porcelain -- .github/CODEOWNERS |
        grep -q "^??"' sh "$SKIP_PROJ"
# shell-robustness: end-exempt

# Move the original mutable tag after the guarded snapshot exists. Copier 9.16
# re-describes the baseline internally, so this proves its nested clone resolves
# against the frozen local tag mapping instead of the changed source repository.
git --git-dir="$GU_REMOTE" tag -f v1.0.0 "$GU_TARGET_COMMIT" >/dev/null
git -C "$GU_TARGET" switch -c guarded-wrong-branch >/dev/null
expect_fail "guarded update state rejects another branch at the same HEAD" \
    sh -c 'test "$(cat "$1/.copier-guarded-update/start-checkout")" = \
        "branch:$(git -C "$1" symbolic-ref --quiet --short HEAD)"' sh \
    "$GU_TARGET"
git -C "$GU_TARGET" switch main >/dev/null
printf '%s\n' intervening >"$GU_TARGET/intervening.txt"
expect_fail "guarded apply rejects intervening untracked worktree changes" \
    sh -c 'test -z "$(git -C "$1" status --porcelain)"' sh "$GU_TARGET"
rm "$GU_TARGET/intervening.txt"
tar -C "$GU_TARGET" \
    -cf "$GU_TARGET/.copier-guarded-update/ignored-preapply.tar" \
    -T "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
expect_ok "guarded apply verifies ignored managed paths before mutation" \
    sh -c 'test "$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/ignored-preapply.tar")" = \
        "$(cat "$1/.copier-guarded-update/ignored-backup-oid")"' sh \
    "$GU_TARGET"
rm "$GU_TARGET/.copier-guarded-update/ignored-preapply.tar"
GU_APPLY_PHASE_CANDIDATE="$GU_TARGET/.copier-guarded-update/apply-phase.candidate"
printf '%s\n' applying >"$GU_APPLY_PHASE_CANDIDATE"
mv "$GU_APPLY_PHASE_CANDIDATE" \
    "$GU_TARGET/.copier-guarded-update/apply-phase"
expect_ok "guarded Copier update survives a source release retag" \
    env \
    "COPIER_CACHE_DIR=$GU_CACHE" \
    GIT_CONFIG_COUNT=2 \
    "GIT_CONFIG_KEY_0=url.$GU_SNAPSHOT.insteadOf" \
    "GIT_CONFIG_VALUE_0=$GU_CANONICAL_SOURCE.git" \
    "GIT_CONFIG_KEY_1=url.$GU_SNAPSHOT.insteadOf" \
    "GIT_CONFIG_VALUE_1=$GU_CANONICAL_SOURCE" \
    copier update --trust --defaults \
    --vcs-ref="$GU_TARGET_COMMIT" \
    --data-file="$GU_TARGET_REAL/.copier-guarded-update/reviewed-data.yml" \
    "$GU_TARGET_REAL"
expect_ok "guarded recovery retains write-ahead applying state after a crash window" \
    grep -qxF applying "$GU_TARGET/.copier-guarded-update/apply-phase"
expect_fail "guarded recovery never promotes an ambiguous applying state" \
    sh -c 'case "$(cat "$1/.copier-guarded-update/apply-phase")" in
        applied) exit 0 ;;
        applying) exit 1 ;;
        *) exit 2 ;;
    esac' sh "$GU_TARGET"
printf '%s\n' applied >"$GU_TARGET/.copier-guarded-update/apply-phase"
expect_ok "guarded Copier update applies the intended target content" \
    grep -qxF target "$GU_TARGET/version.txt"
# THE payoff assertion of the redesign: replay §4's reconciliation against the
# tree the REAL update produced and require every observation to hold. The
# rehearsal ran the same copier, ref and answers against a copy; if these ever
# disagree the environment moved, and §4 stops the hand-off rather than
# publishing a report about a tree that does not exist.
cp "$GU_NONADOPT_TSV" "$TMPROOT/nonadoption-report.pre-reconcile.tsv"
expect_ok "every rehearsed observation holds against the real apply" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$GU_TARGET" "$GU_RECONCILE"
# The verdict is FROZEN at the moment of the apply, because §3 is about to make
# deliberate changes that a later presence check would read as divergence.
expect_ok "a clean reconciliation freezes its verdict" \
    grep -qx 'reconciled: clean' \
    "$GU_TARGET/.copier-guarded-update/nonadoption-reconciled"
# The recreate, confirmed on the real tree rather than on the copy.
expect_ok "the real update recreated the _skip_if_exists path too" \
    test -e "$GU_TARGET/.github/CODEOWNERS"
expect_fail "the real update left the declined both-renders file absent" \
    test -e "$GU_TARGET/shared-note.md"
# And the reconciliation FAILS CLOSED when reality disagrees: remove a file the
# rehearsal observed being created and it must report and return non-zero.
cp "$GU_TARGET/.github/CODEOWNERS" "$TMPROOT/codeowners.bak"
rm "$GU_TARGET/.github/CODEOWNERS"
cp "$TMPROOT/nonadoption-report.pre-reconcile.tsv" "$GU_NONADOPT_TSV"
rm -f "$GU_TARGET/.copier-guarded-update/nonadoption-reconciled"
expect_fail "reconciliation returns non-zero when the applied tree diverges" \
    sh -c 'cd "$1" && bash -eu "$2"' sh "$GU_TARGET" "$GU_RECONCILE"
expect_fail "a diverged reconciliation freezes no verdict" \
    test -e "$GU_TARGET/.copier-guarded-update/nonadoption-reconciled"
cp "$TMPROOT/codeowners.bak" "$GU_TARGET/.github/CODEOWNERS"
cp "$TMPROOT/nonadoption-report.pre-reconcile.tsv" "$GU_NONADOPT_TSV"
# The gotcha, proven end to end by a real `copier update`. shared-note.md is in
# both renders and unchanged between them, so the baseline→target diff says
# nothing about it and the repo's deletion stands — no conflict, no mention.
# The two assertions after it are the control: the deletion the TEMPLATE made is
# applied and the file the template ADDED is created, so the absence above is
# not an inert merge, it is the merge working exactly as designed.
expect_ok "copier update never restores a file absent from the repo" \
    test ! -e "$GU_TARGET/shared-note.md"
expect_ok "copier update applies a template-side deletion" \
    test ! -e "$GU_TARGET/retired-doc.md"
expect_ok "copier update creates a file the target template added" \
    test -f "$GU_TARGET/new-doc.md"
if grep -qxF .gitignore < <(git -C "$GU_TARGET" diff --name-only --diff-filter=U); then
    printf '%s\n' '.vscode/*' \
        '!.vscode/settings.json' \
        '!.vscode/new.json' >"$GU_TARGET/.gitignore"
    git -C "$GU_TARGET" add -- .gitignore
fi
expect_ok "guarded Copier update leaves canonical answers conflict-free" \
    sh -c 'yq -e "." "$1/.copier-answers.yml" >/dev/null &&
        test -z "$(git -C "$1" diff --name-only --diff-filter=U)"' sh \
    "$GU_TARGET"
GU_APPLIED_REF="$(
    yq -r '._commit // ""' "$GU_TARGET/.copier-answers.yml"
)"
GU_APPLIED_COMMIT="$(
    git -C "$GU_SNAPSHOT" rev-parse "$GU_APPLIED_REF^{commit}"
)"
expect_ok "guarded Copier update records the validated applied target" \
    test "$GU_APPLIED_COMMIT" = "$GU_TARGET_COMMIT"
expect_ok "guarded Copier update retains the canonical source URL" \
    test "$(yq -r '._src_path' "$GU_TARGET/.copier-answers.yml")" = \
    "$GU_CANONICAL_SOURCE"
expect_ok "guarded update state remains bound to checkout and original answers" \
    sh -c 'test "$(cat "$1/.copier-guarded-update/start-head")" = \
            "$(git -C "$1" rev-parse HEAD)" &&
        test "$(cat "$1/.copier-guarded-update/canonical-answers-oid")" = \
            "$(git -C "$1" hash-object \
                "$1/.copier-guarded-update/original-answers.yml")"' sh \
    "$GU_TARGET"
expect_ok "guarded Copier update applies the exact reviewed answers" \
    sh -c 'test "$(yq -r ".use_foreman" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_coderabbit" "$1/.copier-answers.yml")" = false &&
        test "$(yq -r ".use_codeql" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_codex_review" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_codex_cloud_review" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".use_skills_sync" "$1/.copier-answers.yml")" = true &&
        test "$(yq -o=json -I=0 ".skill_categories" \
            "$1/.copier-answers.yml")" = "[\"universal\"]" &&
        test "$(yq -o=json -I=0 ".codeql_languages" \
            "$1/.copier-answers.yml")" = "[\"javascript-typescript\"]" &&
        test "$(yq -r ".deploy_preview" "$1/.copier-answers.yml")" = true &&
        test "$(yq -r ".preview_region" "$1/.copier-answers.yml")" = ord &&
        ! yq -e "has(\"hidden_rollout\")" "$1/.copier-answers.yml" \
            >/dev/null' sh \
    "$GU_TARGET"
expect_ok "guarded recovery validates every reviewed answer before promotion" \
    sh -c 'while IFS= read -r key; do
        KEY="$key" yq -e "has(strenv(KEY))" "$1/.copier-answers.yml" \
            >/dev/null || exit 1
        actual="$(KEY="$key" yq -o=json -I=0 \
            ".[strenv(KEY)]" "$1/.copier-answers.yml")"
        expected="$(KEY="$key" yq -o=json -I=0 \
            ".[strenv(KEY)]" "$1/.copier-guarded-update/reviewed-data.yml")"
        test "$actual" = "$expected" || exit 1
    done <"$1/.copier-guarded-update/reviewed-keys"' sh \
    "$GU_TARGET"
printf '%s\n' '{"setting":"interrupted"}' >"$GU_TARGET/.vscode/settings.json"
while IFS= read -r absent_ignored_path; do
    rm -f "$GU_TARGET/$absent_ignored_path"
done <"$GU_TARGET/.copier-guarded-update/ignored-absent-paths"
tar -C "$GU_TARGET" \
    -xf "$GU_TARGET/.copier-guarded-update/ignored-backup.tar"
tar -C "$GU_TARGET" \
    -cf "$GU_TARGET/.copier-guarded-update/ignored-verify.tar" \
    -T "$GU_TARGET/.copier-guarded-update/ignored-existing-paths"
expect_ok "guarded rollback restores and verifies ignored managed files" \
    sh -c 'grep -qxF "{\"setting\":\"custom\"}" \
            "$1/.vscode/settings.json" &&
        grep -qxF "{\"legacy\":\"custom\"}" \
            "$1/.vscode/legacy.json" &&
        test ! -e "$1/.vscode/new.json" &&
        test "$(git -C "$1" hash-object \
            "$1/.copier-guarded-update/ignored-verify.tar")" = \
        "$(cat "$1/.copier-guarded-update/ignored-backup-oid")"' sh \
    "$GU_TARGET"
rm "$GU_TARGET/.copier-guarded-update/ignored-verify.tar"
expect_fail "guarded Copier update state refuses a concurrent or blind retry" \
    mkdir "$GU_TARGET/.copier-guarded-update"
git -C "$GU_TARGET" add -A
GU_PROMOTED_ANSWERS="$GU_TARGET/.copier-answers.yml.promote"
cp "$GU_TARGET/.copier-answers.yml" "$GU_PROMOTED_ANSWERS"
GU_CANONICAL_SOURCE="$GU_CANONICAL_SOURCE" \
    GU_TARGET_COMMIT="$GU_TARGET_COMMIT" \
    yq -i \
    '._src_path = strenv(GU_CANONICAL_SOURCE) |
     ._commit = strenv(GU_TARGET_COMMIT)' \
    "$GU_PROMOTED_ANSWERS"
mv "$GU_PROMOTED_ANSWERS" "$GU_TARGET/.copier-answers.yml"
git -C "$GU_TARGET" add -- .copier-answers.yml
expect_ok "promoted full-hash answers replace the staged tag lineage" \
    sh -c 'git -C "$1" show :.copier-answers.yml |
        EXPECTED_COMMIT="$2" yq -e "._commit == strenv(EXPECTED_COMMIT)" - \
            >/dev/null' sh \
    "$GU_TARGET" "$GU_TARGET_COMMIT"
chmod -R u+w "$GU_SNAPSHOT"

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
moved = {"prepare", "discover", "rehearse", "present", "apply"}
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
