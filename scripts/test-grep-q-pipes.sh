#!/usr/bin/env bash
# Reject printf/echo producers piped into grep -q: under pipefail an early
# match can SIGPIPE the producer and turn a match into failure. Use a here-string.
# Scans shell scripts (including conditional Copier names and .sh.jinja),
# Taskfile `cmds:`, `status:`, and `preconditions:` keys at any depth (when no
# body is already open), scanning inline values and indented bodies, including
# block scalars and single-line flow sequences; multi-line flow items are
# scanned only when indented past their key. Text under scanned bodies is
# included, including call-vars `sh:` inside `cmds:`. A task named `cmds`,
# `status`, or `preconditions`, or a `status:` text line inside a block such as
# `summary: |`, also opens a scan. These fail-safe over-scans can add diagnostics,
# never hide one.
# Workflow `run:` bodies are scanned too.
# Generated repos need no `template/` tree.
# Taskfile forms out of scope: short task syntax (scalar, sequence, flow); all
# folded or plain multi-line scalars whose `|` starts the continuation line;
# spaced keys such as `status :`, `cmds :`, and `preconditions :`; multi-line
# flow lists whose items are not indented past the key; `sh:` values outside
# scanned bodies (such as env `sh:` and task-level dynamic vars); YAML aliases
# such as `cmds: *anchor`; flow-mapping tasks; compact (indentless) sequences;
# multiline block scalars outside the three scanned keys; task-level `cmd:` and
# `if:`; quoted keys. Workflow `run :` keys are also out of scope.
# A same-line `# grep-q-pipe: allow -- REASON` exempts an intentional fixture;
# the reason must contain a non-whitespace character. Full-line comments do not
# execute and are ignored. Matching uses POSIX ERE, including flag clusters.
# This line-oriented heuristic checks the common printf/echo ... | grep -q form. # shell-robustness: ok — documents the forbidden shape
# It is not a shell parser: pipe text inside quotes and pipelines continued
# after a trailing comment are out of scope. Such constructs can false-positive
# (use the allow pragma) or slip through (preserve the pipe-free idiom by review).
set -euo pipefail
cd "$(dirname "$0")/.."

scan() {
    awk -v kind="$2" '
        function inspect(text, line) {
            if (text ~ /^[[:space:]]*#/) return
            if (text ~ /# grep-q-pipe: allow --[[:space:]]*[^[:space:]]/) return
            if (text ~ /(^|[[;&|()[:space:]\047"])(printf|echo)[[:space:]].*[|][[:space:]]*grep([[:space:]]+-[[:alpha:]]+)*[[:space:]]+-[[:alpha:]]*q[[:alpha:]]*([[:space:]]|$)/) {
                printf "%s:%d: producer piped into grep -q: %s\n", FILENAME, line, text
                bad = 1
            }
        }
        function command(text) {
            if (text ~ /^[[:space:]]*(#|$)/) return
            if (!pending) start = FNR
            pending = pending text
            if (pending ~ /([\\|])[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", pending)
                return
            }
            inspect(pending, start)
            pending = ""
        }
        {
            if (kind == "shell") { command($0); next }
            # Jinja control lines have no YAML indentation and no shell body.
            if ($0 ~ /^[[:space:]]*\[%/) next
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            indent = match($0, /[^ ]/) - 1
            if (active && indent <= boundary) {
                inspect(pending, start)
                pending = ""
                active = 0
            }
            if (!active && ((kind == "task" && $0 ~ /^[[:space:]]*(cmds|status|preconditions):/) ||
                (kind == "workflow" && $0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/))) {
                active = 1
                boundary = indent
                text = $0
                sub(/^[[:space:]]*(-[[:space:]]+)?(cmds|status|preconditions|run):[[:space:]]*/, "", text)
                if (text !~ /^([|>][-+]?|\[)?[[:space:]]*$/) command(text)
                next
            }
            if (active) command($0)
        }
        END { inspect(pending, start); exit bad }
    ' "$1"
}

# Exercise the same scanner before trusting its repository-wide result. Keep
# fixture pipes out of this source so the guard does not flag its own tests.
self_test() (
    fixtures="$(mktemp -d)"
    trap 'rm -rf "$fixtures"' EXIT
    printf 'printf "%%s\\n" "$x" %s grep -q PATTERN\n' '|' >"$fixtures/bad.sh"
    printf 'tasks:\n  test:\n    cmds:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/task.yml"
    printf 'steps:\n  - run: |\n      echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/workflow.yml"
    printf 'tasks:\n  test:\n    cmds: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/inline-task.yml"
    printf 'tasks:\n  test:\n    cmds: [echo "$x" %s grep -q PATTERN]\n' '|' >"$fixtures/flow-task.yml"
    printf 'tasks: &t\n  test:\n    cmds:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/anchored-task.yml"
    printf 'tasks:\n  test:\n    status: |\n      echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/status-block-task.yml"
    printf 'tasks:\n  test:\n    status: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/status-inline-task.yml"
    printf 'tasks:\n  test:\n    status: [echo "$x" %s grep -q PATTERN]\n' '|' >"$fixtures/status-flow-task.yml"
    printf 'tasks:\n  test:\n    preconditions:\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/preconditions-block-task.yml"
    printf 'tasks:\n  a:\n    preconditions:\n      - sh: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/preconditions-sh-task.yml"
    printf 'tasks:\n  test:\n    preconditions: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/preconditions-inline-task.yml"
    printf 'tasks:\n  test:\n    preconditions: [echo "$x" %s grep -q PATTERN]\n' '|' >"$fixtures/preconditions-flow-task.yml"
    printf 'tasks:\n  default:\n    cmds:\n      - |\n        status: enabled\n      - echo abc %s grep -q abc && echo SECOND-RAN\n' '|' >"$fixtures/nested-status-boundary-task.yml"
    printf 'tasks:\n  notify:\n    cmds:\n      - task: something\n        vars:\n          status: ok\n      - echo abc %s grep -q abc && echo SECOND-RAN\n' '|' >"$fixtures/nested-vars-status-boundary-task.yml"
    printf 'tasks:\n  default:\n    cmds:\n      - task: nested\n        vars:\n          X:\n            sh: |\n              echo safe\n      - echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/nested-sh-boundary-task.yml"
    printf 'steps:\n  - run: echo "$x" %s grep -q PATTERN\n' '|' >"$fixtures/inline-workflow.yml"
    printf 'steps:\n  - run: |\n      - run: |\n      echo abc %s grep -q abc && echo SECOND-RAN\n' '|' >"$fixtures/nested-run-boundary-workflow.yml"
    printf 'echo "$x" %s\n    grep -q PATTERN\n' '|' >"$fixtures/continued.sh"
    printf 'echo "$x" %s grep -Fq PATTERN\n' '|' >"$fixtures/clustered.sh"
    printf 'echo "$x" %s grep -E -q PATTERN\n' '|' >"$fixtures/separate.sh"
    printf 'echo "$x" %s grep -q PATTERN # grep-q-pipe: allow --   \n' '|' >"$fixtures/empty-reason.sh"
    printf 'grep -q PATTERN <<<"$(printf "%%s\\n" "$x")"\n' >"$fixtures/good.sh"
    printf 'echo "$x" %s grep -q PATTERN # grep-q-pipe: allow -- intentional fixture\n' '|' >"$fixtures/allowed.sh"
    printf 'printf "%%s\\n" "$x" >"$f"; grep -q PATTERN "$f"\n' >"$fixtures/pipe-free.sh"
    for fixture in bad.sh continued.sh clustered.sh separate.sh empty-reason.sh task.yml workflow.yml inline-task.yml inline-workflow.yml nested-run-boundary-workflow.yml flow-task.yml anchored-task.yml status-block-task.yml status-inline-task.yml status-flow-task.yml preconditions-block-task.yml preconditions-sh-task.yml preconditions-inline-task.yml preconditions-flow-task.yml nested-status-boundary-task.yml nested-vars-status-boundary-task.yml nested-sh-boundary-task.yml; do
        case "$fixture" in
        *.sh) kind=shell ;;
        *task.yml) kind=task ;;
        *workflow.yml) kind=workflow ;;
        *)
            echo "test-grep-q-pipes: unclassified fixture $fixture" >&2
            exit 1
            ;;
        esac
        if scan "$fixtures/$fixture" "$kind" >"$fixtures/output"; then
            echo "test-grep-q-pipes: self-test failed: missed $fixture" >&2
            exit 1
        fi
        if [ ! -s "$fixtures/output" ]; then
            echo "test-grep-q-pipes: self-test failed: no diagnostic for $fixture" >&2
            exit 1
        fi
        if [ "$fixture" = status-block-task.yml ] && ! grep -Eq 'status-block-task\.yml:4: producer piped into grep -q:' "$fixtures/output"; then
            echo "test-grep-q-pipes: self-test failed: wrong reported line for $fixture" >&2
            cat "$fixtures/output" >&2
            exit 1
        fi
    done
    for fixture in good.sh allowed.sh pipe-free.sh; do
        if ! scan "$fixtures/$fixture" shell >"$fixtures/output"; then
            echo "test-grep-q-pipes: self-test failed: rejected $fixture" >&2
            cat "$fixtures/output" >&2
            exit 1
        fi
    done
)
self_test

roots=()
for dir in scripts template .devcontainer .github taskfiles images sprites; do
    [ ! -d "$dir" ] || roots+=("$dir")
done
failed=0
while IFS= read -r -d '' file; do
    kind=""
    # Copier conditionals can wrap filenames or directory names. Classify the
    # rendered shape, but inspect and report the original source path.
    norm="$(sed 's/\[%[^%]*%\]//g' <<<"$file")"
    case "$norm" in
    *.sh | *.sh.jinja) kind=shell ;;
    */Taskfile.yml | */Taskfile.yaml | */Taskfile.yml.jinja | */Taskfile.yaml.jinja | taskfiles/*.yml | taskfiles/*.yaml | */taskfiles/*.yml | */taskfiles/*.yml.jinja | */taskfiles/*.yaml | */taskfiles/*.yaml.jinja) kind=task ;;
    .github/workflows/*.yml | .github/workflows/*.yaml | */.github/workflows/*.yml | */.github/workflows/*.yml.jinja | */.github/workflows/*.yaml | */.github/workflows/*.yaml.jinja) kind=workflow ;;
    esac
    [ -z "$kind" ] || scan "$file" "$kind" || failed=1
done < <(find "${roots[@]}" -type d \( -name .claude -o -name .agents -o -name node_modules -o -name .venv -o -name .git \) -prune -o -type f -exec printf '%s\000' {} +)
for file in Taskfile.yml Taskfile.yaml; do
    [ ! -f "$file" ] || scan "$file" task || failed=1
done
[ "$failed" -eq 0 ] || exit 1
echo 'test-grep-q-pipes: PASS'
