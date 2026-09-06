#!/usr/bin/env bash
# lint-shell-robustness.sh — guard the two shell idioms whose EXIT STATUS LIES.
#
# 1. `PRODUCER | grep -q PATTERN` under `set -o pipefail` (#689). # shell-robustness: ok — this line names the shape the guard forbids
#    `grep -q` exits the moment it matches. The producer is usually still
#    writing, so it takes SIGPIPE and dies 141; `pipefail` then reports the
#    whole pipeline as FAILED even though grep MATCHED. Measured here: 0/100
#    false failures at 150 B, 1/100 at 1.5 kB, 94/100 at 84 kB, 200/200 at
#    349 kB. Seen in production, not just tests — the triage skill's
#    `axes_active()` silently dropped a classification axis this way.
#
#      grep -qF "$needle" <<<"$haystack"          # a string
#      grep -q PATTERN < <(some-command --args)   # a command
#      out="$(cmd)" && grep -q PATTERN <<<"$out"  # when cmd's success is
#                                                 # itself part of the check
#
# 2. A test reporter (`ok`, `bad`, `pass`, …) that does not end in `return 0`.
#    Assertions are written `check && ok "…" || bad "…"`, so the reporter's own
#    status sits inside the branch: if its `echo` fails on the grouped-output
#    pipe `task` runs suites under, a PASSING assertion reports as a failure.
#
#      ok() {
#          pass=$((pass + 1))
#          echo "  ✓ $*" || true
#          return 0
#      }
#
# WHY THIS IS DELIBERATELY OVER-EAGER, AND HAS NO PARSER
#
# The first version of this guard parsed shell: it tracked quote, here-doc and
# command-substitution state so it could tell code from text. Four adversarial
# review rounds found ELEVEN ways to make that lexer report a file clean while
# the forbidden construct was plainly present — a herestring read as a here-doc
# opener, an apostrophe in a comment, a multi-line command substitution, a
# quote closing mid-line, several here-docs on one line, `<<EOF-X`, backticks,
# continued option lines, a brace on its own line, and more. Shell grammar is
# much larger than any subset a guard can afford to model, so that list was
# never going to close.
#
# A guard that reports a dirty tree CLEAN is worse than no guard, because
# people trust it. So this version does not try to be clever: it matches TEXT,
# flags everything that looks like the forbidden shape — inside comments, inside
# here-doc bodies, inside quoted strings, everywhere — and makes each genuine
# exception state itself out loud:
#
#   … code …                # shell-robustness: ok — why this one is fine
#
#   # shell-robustness: begin-exempt — why this whole region is fine
#   … lines, e.g. a here-doc whose body must stay byte-exact …
#   # shell-robustness: end-exempt
#
#   # shell-robustness: exempt-file — why every match in this file is deliberate
#
# Every form REQUIRES a reason after the em dash (or `--`); a marker without one
# is itself an error, so the escape hatch cannot be used silently. False
# positives are loud and cost a reviewer one annotation. False negatives were
# invisible and cost four review rounds.
#
# Scope: every tracked *.sh / *.bash except snippets/ — the same set
# scripts/shell-quality.sh lints. The reporter check additionally applies only
# to test-*.sh suites.
#
# Usage: ./scripts/lint-shell-robustness.sh [file ...]
#   With no arguments, checks every tracked file in scope.
set -euo pipefail

REPO_ONLY=0
files=()
if [ $# -gt 0 ]; then
    files=("$@")
    for f in "$@"; do
        [ -f "$f" ] || {
            # A path the caller NAMED and that is not there is an error, never
            # a clean file: this guard must not report on what it never read.
            echo "lint-shell-robustness: no such file: $f" >&2
            exit 1
        }
    done
else
    REPO_ONLY=1
    cd "$(git rev-parse --show-toplevel)"
    # EVERY tracked shell file, matching scripts/shell-quality.sh. A guard
    # scoped to scripts/ and ai/skills/ reported the repository clean while
    # `.claude/hooks/` and `.devcontainer/` carried the defect — including two
    # hooks that fail OPEN on it (see the exemption reasons there).
    # Snippets are excluded for the same reason shell-quality excludes them:
    # they are deliberately incomplete fragments.
    #
    # NUL-delimited: a tracked filename may legally contain a newline, and
    # splitting one into nonexistent pieces would silently shrink the scan.
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(git ls-files -z -- '*.sh' '*.bash' ':(exclude)snippets/**')
fi

[ ${#files[@]} -gt 0 ] || {
    echo "lint-shell-robustness: no shell scripts in scope" >&2
    exit 1
}

findings="$(mktemp)"
trap 'rm -f "${findings}"' EXIT

for f in "${files[@]}"; do
    awk -v FILE="$f" '
    # The reason must follow the MARKER. Matching a dash anywhere on the line
    # let an earlier `--option` stand in for it, so
    # `producer | grep --quiet x # shell-robustness: ok` passed with no reason
    # at all — silently, which is the one thing this design exists to prevent.
    function reason_ok(s,   t) {
        t = s
        if (!sub(/^.*shell-robustness:[[:space:]]*(ok|begin-exempt|exempt-file)[[:space:]]*/, "", t)) return 0
        return (t ~ /^(—|--)[[:space:]]*[^[:space:]]/)
    }

    # Exemption markers. Each needs a reason; a bare marker is itself reported.
    /shell-robustness:[[:space:]]*exempt-file/ {
        if (reason_ok($0)) { exempt_file = 1 } else { printf "%s:%d: `exempt-file` marker with no reason after the dash\n", FILE, FNR }
        next
    }
    /shell-robustness:[[:space:]]*begin-exempt/ {
        if (reason_ok($0)) { block = 1; block_line = FNR } else { printf "%s:%d: `begin-exempt` marker with no reason after the dash\n", FILE, FNR }
        next
    }
    /shell-robustness:[[:space:]]*end-exempt/ {
        if (!block) printf "%s:%d: `end-exempt` with no open `begin-exempt`\n", FILE, FNR
        block = 0
        block_line = 0
        next
    }

    {
        line = $0
        inline_ok = 0
        if (line ~ /shell-robustness:[[:space:]]*ok/) {
            if (reason_ok(line)) inline_ok = 1
            # A reasonless marker is a finding — but not inside a region that
            # is already exempt, where the marker is fixture text rather than
            # a live claim.
            else if (!exempt_file && !block) printf "%s:%d: `ok` marker with no reason after the dash\n", FILE, FNR
        }
        skip = (exempt_file || block || inline_ok)

        # R1 — a pipe feeding a grep that carries a quiet flag.
        if (!skip && line ~ /(^|[^|])\|[[:space:]]*grep([[:space:]]+-[^[:space:]|]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
            printf "%s:%d: `| grep -q` — grep exits on match, SIGPIPEs the producer, and `pipefail` turns a MATCH into a failure\n", FILE, FNR
        # R2 — a pipe feeding a grep whose options continue on the next line.
        else if (!skip && line ~ /(^|[^|])\|[[:space:]]*grep([[:space:]]+-[^[:space:]|]+)*[[:space:]]*\\[[:space:]]*$/)
            printf "%s:%d: `| grep \\` — options continue on the next line; a quiet flag here would be the SIGPIPE shape\n", FILE, FNR
        # R3a — the previous line ends with a SINGLE pipe (not `||`, which is
        # an or-list, and not `\`, which continues an argument list) and this
        # line leads with a quiet grep.
        else if (!skip && prev ~ /(^|[^|])\|[[:space:]]*$/ &&
                 line ~ /^[[:space:]]*grep([[:space:]]+-[^[:space:]|]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
            printf "%s:%d: continued `| grep -q` pipeline — same SIGPIPE shape, split across lines\n", FILE, FNR
        # R3b — this line itself leads with the pipe (`producer \` then `| grep -q`).
        else if (!skip && line ~ /^[[:space:]]*\|[[:space:]]*grep([[:space:]]+-[^[:space:]|]+)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([[:space:]]|$)/)
            printf "%s:%d: continued `| grep -q` pipeline — same SIGPIPE shape, split across lines\n", FILE, FNR

        prev = $0
    }

    # An unclosed block would suppress every later finding in the file, so the
    # typo must be the error rather than a silent licence.
    END {
        if (block) printf "%s:%d: `begin-exempt` is never closed — everything after it would be silently exempt\n", FILE, block_line
    }
    ' "$f"
done >>"$findings"

# ── reporter helpers (test suites only) ─────────────────────────────────────
for f in "${files[@]}"; do
    case "$f" in
    */test-*.sh | test-*.sh) ;;
    *) continue ;;
    esac
    awk -v FILE="$f" '
    # The reason must follow the MARKER. Matching a dash anywhere on the line
    # let an earlier `--option` stand in for it, so
    # `producer | grep --quiet x # shell-robustness: ok` passed with no reason
    # at all — silently, which is the one thing this design exists to prevent.
    function reason_ok(s,   t) {
        t = s
        if (!sub(/^.*shell-robustness:[[:space:]]*(ok|begin-exempt|exempt-file)[[:space:]]*/, "", t)) return 0
        return (t ~ /^(—|--)[[:space:]]*[^[:space:]]/)
    }
    /shell-robustness:[[:space:]]*exempt-file/ { if (reason_ok($0)) exempt_file = 1; next }
    /shell-robustness:[[:space:]]*begin-exempt/ { if (reason_ok($0)) block = 1; next }
    /shell-robustness:[[:space:]]*end-exempt/ { block = 0; next }
    exempt_file || block { next }

    # A ONE-LINE definition: `ok() { …; }`. This repo used that spelling until
    # this change converted it, so a guard that ignores it would not stop its
    # return. The body is whatever sits between the braces.
    $0 ~ /^[[:space:]]*(function[[:space:]]+)?(ok|bad|pass|fail|failed|good|note|warn|skip|skipped|report)[[:space:]]*(\(\))?[[:space:]]*\{.*\}[[:space:]]*$/ &&
    $0 ~ /(^[[:space:]]*function[[:space:]]|\(\))/ {
        name = $0
        sub(/^[[:space:]]*function[[:space:]]+/, "", name)
        sub(/[[:space:]]*\(\).*$/, "", name)
        sub(/[[:space:]]*\{.*$/, "", name)
        gsub(/[[:space:]]/, "", name)
        inner = $0
        sub(/^[^{]*\{/, "", inner)
        sub(/\}[[:space:]]*$/, "", inner)
        if (inner !~ /(^|[[:space:];&|(])exit([[:space:]]|$)/ &&
            !($0 ~ /shell-robustness:[[:space:]]*ok/ && reason_ok($0)) &&
            inner !~ /;[[:space:]]*return 0[[:space:]]*;?[[:space:]]*$/)
            printf "%s:%d: reporter `%s()` must end with `return 0` — otherwise its own status is read as the assertion s\n", FILE, FNR, name
        next
    }

    # All four bash spellings, plus the brace on its own line.
    $0 ~ /^[[:space:]]*(function[[:space:]]+)?(ok|bad|pass|fail|failed|good|note|warn|skip|skipped|report)[[:space:]]*(\(\))?[[:space:]]*(\{)?[[:space:]]*$/ &&
    $0 ~ /(^[[:space:]]*function[[:space:]]|\(\))/ {
        name = $0
        sub(/^[[:space:]]*function[[:space:]]+/, "", name)
        sub(/[[:space:]]*\(\).*$/, "", name)
        sub(/[[:space:]]*\{.*$/, "", name)
        gsub(/[[:space:]]/, "", name)
        open = FNR; fname = name; last = ""; exits = 0; ann = 0
        for (i = FNR; i <= FNR + 60; i++) {
            if ((getline nxt) <= 0) break
            if (nxt ~ /shell-robustness:[[:space:]]*ok/ && reason_ok(nxt)) ann = 1
            if (nxt ~ /(^|[[:space:];&|(])exit([[:space:]]|$)/) exits = 1
            if (nxt ~ /^[[:space:]]*\}[[:space:]]*$/) {
                if (!exits && !ann && last !~ /^[[:space:]]*return 0[[:space:]]*;?[[:space:]]*$/)
                    printf "%s:%d: reporter `%s()` must end with `return 0` — otherwise its own status is read as the assertion s\n", FILE, open, fname
                break
            }
            if (nxt ~ /[^[:space:]]/ && nxt !~ /^[[:space:]]*#/) last = nxt
        }
        next
    }
    ' "$f"
done >>"$findings"

if [ -s "$findings" ]; then
    sort -t: -k1,1 -k2,2n "$findings" >&2
    echo >&2
    echo "lint-shell-robustness: $(wc -l <"${findings}" | tr -d ' ') finding(s)." >&2
    echo "  Fixed shapes and the exemption markers are documented at the top of" >&2
    echo "  scripts/lint-shell-robustness.sh. This guard is deliberately over-eager:" >&2
    echo "  if a match is genuinely fine, say so inline with a reason." >&2
    exit 1
fi

if [ "$REPO_ONLY" -eq 1 ]; then
    echo "lint-shell-robustness: ${#files[@]} tracked file(s) clean"
else
    echo "lint-shell-robustness: ${#files[@]} file(s) clean"
fi
