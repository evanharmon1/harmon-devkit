#!/usr/bin/env bash
# test-registry-docs.sh — GATE the human-facing agent-registry tables in
# docs/project-management.md against the machine-readable registry.
#
# ADR 0005 D10 makes that document the human authority for the agent
# vocabulary, and D11 says the registry has executable teeth. A markdown table
# maintained by hand satisfies neither: it drifts the moment a family or
# harness is added, and nothing fails. So the tables are GENERATED —
# `node scripts/agent-registry-labels.mjs docs-tables` — and pasted between
# markers, and this check regenerates them and fails on any difference.
#
#   <!-- registry-tables:begin -->
#   ...generated tables...
#   <!-- registry-tables:end -->
#
# Two modes, decided by whether this repository is a COPY of a template (it has
# a Copier answers file) or the template itself (no answers file, but it ships
# the project-management jinja twins):
#
#   TEMPLATE repository — both layers are REQUIRED: the root dogfood copy
#     docs/project-management.md and the jinja twin that ships it. The twin is
#     deliberately covered here rather than by the dogfood checks:
#     test-dogfood-parity.sh skips it (it is a .jinja file) and
#     test-dogfood-structure.sh SKIPs docs/project-management.md outright (its
#     root copy is not a render of the template copy), so without this the
#     generated tables could ship stale to every consumer while the root copy
#     stayed current. The registry itself is a verbatim twin, so both layers
#     render byte-identical tables and one expected value serves both.
#
#   GENERATED repository — the document is required when the repo was rendered
#     with `project_management: github`, and only then. The `linear` and `none`
#     answers render a different document at the same path, or none at all.
#
# A MISSING expected document is a failure, never a skip: the whole point of
# the gate is that the published tables cannot silently stop existing.
#
# Usage: test-registry-docs.sh [--answers-file <name>] [registry-path]
#        COPIER_ANSWERS_FILE=<name> test-registry-docs.sh
#
# Both name Copier's answers file, whose name is configurable
# (`_copier_conf.answers_file`) — the generated Taskfile sets the environment
# variable so a repository copied with `--answers-file custom.yml` still
# resolves its tracker. It arrives at runtime rather than being templated in
# because this script is a verbatim root<->template twin: it must be
# byte-identical in both layers. The environment variable is what the Taskfile
# uses because a Taskfile carries it through YAML and then a shell word — a
# name containing an apostrophe would break out of a quoted command argument,
# while an env value is passed to the process untouched.
#
# To fix a drift failure: regenerate and paste the block, keeping the markers.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

answers_file=""
registry=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --answers-file)
        if [ "$#" -lt 2 ]; then
            echo "TEST FAIL: --answers-file needs a value" >&2
            exit 2
        fi
        answers_file="$2"
        shift 2
        ;;
    --answers-file=*)
        answers_file="${1#*=}"
        shift
        ;;
    -*)
        echo "TEST FAIL: unknown argument: $1" >&2
        exit 2
        ;;
    *)
        registry="$1"
        shift
        ;;
    esac
done

registry="${registry:-agent-registry.json}"
renderer="scripts/agent-registry-labels.mjs"
doc="docs/project-management.md"
begin='<!-- registry-tables:begin -->'
end='<!-- registry-tables:end -->'

for required in "$registry" "$renderer"; do
    [ -f "$required" ] || {
        echo "TEST FAIL: missing required registry asset: $required" >&2
        exit 1
    }
done
command -v node >/dev/null 2>&1 || {
    echo "TEST FAIL: node is required to render the registry documentation tables" >&2
    exit 1
}

# Compare through FILES, never through `$(…)` capture. Command substitution
# strips trailing newlines from what it captures, so blank lines added just
# inside the end marker would vanish from both sides and an "exact" comparison
# would pass over real edits to the generated block.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
node "$renderer" docs-tables "$registry" >"$work/expected"

# The project-management jinja twins. `any_twin` matches either tracker variant
# and is the shape only the harmon-init template has; `twin` is the GitHub one
# specifically, so the `linear` variant — a different tracker, with no label
# taxonomy and no registry tables — is never checked for registry tables.
twin=""
any_twin=""
for candidate in template/docs/*project-management.md*.jinja; do
    [ -f "$candidate" ] || continue
    any_twin="$candidate"
    case "$candidate" in
    *github*) twin="$candidate" ;;
    esac
done

# Copier's answers file: the artifact that says "this repository is a COPY of
# some template". Its presence is what separates a generated repository from
# the template itself, and it also records which project-management document
# was rendered. Prefer the name the caller passes (Copier's is configurable),
# then the environment, then Copier's own defaults.
#
# The AMBIENT environment is consulted only where the twin sentinel is absent.
# In the template repository an exported COPIER_ANSWERS_FILE — pointing at, say,
# `.dogfood-answers.yml`, which does exist there — would otherwise flip it into
# generated mode and quietly check one layer instead of two. An explicit
# --answers-file flag still wins everywhere: that is a caller stating intent,
# not an inherited shell.
answers=""
answers_candidates="$answers_file"
if [ -z "$any_twin" ]; then
    answers_candidates="$answers_candidates
${COPIER_ANSWERS_FILE:-}"
fi
answers_candidates="$answers_candidates
.copier-answers.yml
.copier-answers.yaml"
while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -f "$candidate" ]; then
        answers="$candidate"
        break
    fi
done <<EOF
$answers_candidates
EOF

targets=""
# Template mode needs BOTH signals. A bare `template/` directory is not enough:
# adopting this toolchain into an existing repository that is ITSELF a Copier
# template is supported, and such a repo has a `template/docs/` of its own —
# flipping it into dogfood mode would demand a jinja twin it will never have
# and fail its `task verify` forever. An answers file settles it: a copy has
# one, the template does not.
if [ -z "$answers" ] && [ -n "$any_twin" ]; then
    # ── template repository ────────────────────────────────────────────
    # Matching on `any_twin` rather than on `twin` keeps DELETING the GitHub
    # twin a loud failure. Keying the whole mode on the GitHub twin's presence
    # would make its removal fall through to generated mode, where
    # scripts/setup-github-project.sh (which the template repo also carries)
    # infers `github` and only the root copy gets checked — a silent pass for
    # exactly the deletion this branch exists to catch.
    if [ -z "$twin" ]; then
        echo "TEST FAIL: no GitHub project-management twin under template/docs/ — the document that ships the generated registry tables is gone" >&2
        exit 1
    fi
    if [ ! -f "$doc" ]; then
        echo "TEST FAIL: $doc is missing — the root layer must dogfood the document it ships" >&2
        exit 1
    fi
    targets="$doc
$twin
"
else
    # ── generated repository ───────────────────────────────────────────
    # Which document Copier rendered at $doc is decided by the
    # project_management answer, so read the answer rather than sniffing the
    # document's prose. If the answer cannot be read at all, fall back to
    # scripts/setup-github-project.sh, generated by exactly the same condition.
    # Strip an inline YAML comment and surrounding whitespace: a hand-edited
    # `project_management: github  # tracker` is valid YAML and must not read
    # as a non-github tracker (that skip would be a silent fail-open).
    tracker=""
    if [ -n "$answers" ]; then
        tracker="$(sed -n 's/^project_management:[[:space:]]*//p' "$answers" |
            sed 's/[[:space:]]*#.*$//' | tr -d "\"'" |
            sed 's/[[:space:]]*$//' | head -n1)"
    fi
    if [ -z "$tracker" ]; then
        if [ -f scripts/setup-github-project.sh ]; then
            tracker="github"
        else
            tracker="none"
        fi
        echo "note: no project_management answer found; inferred '$tracker' from scripts/setup-github-project.sh" >&2
    fi

    # Fail closed on anything the template does not define: an unrecognized
    # value means the answers file did not parse the way this script assumes,
    # and skipping on it would let a missing or stale document pass verify.
    case "$tracker" in
    github | linear | none) : ;;
    *)
        echo "TEST FAIL: unrecognized project_management value '$tracker' — refusing to skip the docs gate on it" >&2
        exit 1
        ;;
    esac

    if [ "$tracker" != "github" ]; then
        echo "test-registry-docs: skipping — project_management=$tracker renders no GitHub Projects document."
        exit 0
    fi
    if [ ! -f "$doc" ]; then
        echo "TEST FAIL: $doc is missing but project_management=github — the published registry tables are gone" >&2
        exit 1
    fi
    targets="$doc
"
fi

fails=0
checked=0
while IFS= read -r target; do
    [ -n "$target" ] || continue
    checked=$((checked + 1))

    # Exactly one marker pair. Zero means the block was dropped (or never
    # added); more than one means an ambiguous region this check cannot
    # regenerate deterministically.
    begins="$(grep -cxF "$begin" "$target" || true)"
    ends="$(grep -cxF "$end" "$target" || true)"
    if [ "$begins" != 1 ] || [ "$ends" != 1 ]; then
        echo "FAIL: $target must contain exactly one '$begin' line and one '$end' line (found $begins and $ends)" >&2
        fails=$((fails + 1))
        continue
    fi

    # Ordering. One of each is not yet a well-formed region: reversed markers
    # would make the awk below extract everything OUTSIDE the block, and an
    # extraction that never meets its closing marker has swallowed the rest of
    # the file. Both are structural breakage, not drift, so they get their own
    # errors instead of an enormous confusing diff.
    begin_line="$(grep -nxF "$begin" "$target" | cut -d: -f1)"
    end_line="$(grep -nxF "$end" "$target" | cut -d: -f1)"
    if [ "$begin_line" -ge "$end_line" ]; then
        echo "FAIL: $target has its registry-table markers reversed — '$begin' is on line $begin_line, after '$end' on line $end_line" >&2
        fails=$((fails + 1))
        continue
    fi

    awk -v b="$begin" -v e="$end" '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0; closed = 1 }
        inside
        END { exit(closed ? 0 : 1) }' "$target" >"$work/actual" || {
        echo "FAIL: $target has an unclosed registry-table region — extraction from '$begin' never reached '$end'" >&2
        fails=$((fails + 1))
        continue
    }

    if ! diff -u "$work/actual" "$work/expected" >"$work/diff"; then
        echo "FAIL: the registry tables in $target do not match agent-registry.json:" >&2
        cat "$work/diff" >&2
        fails=$((fails + 1))
    fi
done <<EOF
$targets
EOF

if [ "$fails" -ne 0 ]; then
    echo "test-registry-docs: $fails document(s) drifted from agent-registry.json." >&2
    echo "Regenerate with: node $renderer docs-tables $registry" >&2
    echo "and replace the lines between the markers, in every layer that carries them." >&2
    exit 1
fi

echo "test-registry-docs: registry tables in $checked document(s) match agent-registry.json."
