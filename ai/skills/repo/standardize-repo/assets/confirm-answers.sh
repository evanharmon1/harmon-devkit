#!/usr/bin/env bash
#
# confirm-answers.sh — present the complete resolved copier question -> answer
# set for review, then gate the trusted copier run on an explicit confirmation.
#
# Usage:
#   confirm-answers.sh --template-copier <copier.yml> --data-file <answers.yml>
#                      --recorded <.copier-answers.yml|none>
#                      [--active-keys <file>] [--template-commit <sha>]
#                      [--state-dir <dir>] [--confirm]
#   confirm-answers.sh --check --data-file <answers.yml> --state-dir <dir>
#                      [--template-commit <sha>]
#
# Three modes:
#   (default)  print the resolved table and exit 0. Nothing is written.
#   --confirm  print the table AND record <state-dir>/answers-confirmed. Pass
#              this ONLY after a human has seen the printed set and explicitly
#              approved it. An agent never self-approves, and a parallel worker
#              never passes --confirm: it prints the set, stops, and returns it
#              to the parent/human.
#   --check    exit 0 only if the recorded confirmation matches the current data
#              file and template commit. This is what the recipes call
#              immediately before every `copier … --trust` run; it fails closed.
#
# This script NEVER runs copier. It only reads YAML (yq v4) and hashes files
# (git hash-object), so it is safe to run before any trusted execution.
#
# Portable to macOS bash 3.2 (no mapfile, no associative arrays).

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage:
  confirm-answers.sh --template-copier <copier.yml> --data-file <answers.yml> \
                     --recorded <.copier-answers.yml|none> \
                     [--active-keys <file>] [--template-commit <sha>] \
                     [--state-dir <dir>] [--confirm]
  confirm-answers.sh --check --data-file <answers.yml> --state-dir <dir> \
                     [--template-commit <sha>]
USAGE
}

# Security-sensitive questions. harmon-init's copier.yml carries NO
# machine-readable sensitivity marker today, so this list is maintained here and
# widened by a `help:` text match (see sensitivity_of). NEW keys are flagged
# separately precisely so an unknown addition still gets reviewed rather than
# silently passing as ordinary config.
SENSITIVE_KEYS="
foreman_additional_trusted_actors
use_antigravity_cli
claude_authorized_members
code_owner
use_alternative_claude_providers
use_foreman
github_remote_create
github_release_init
bunch_add
obsidian_project_add
run_task_install
git_init
"
SENSITIVE_HELP_RE='security-sensitive|dangerously'

template_copier=""
recorded=""
data_file=""
active_keys=""
template_commit=""
state_dir=""
mode="print"

while [ $# -gt 0 ]; do
    case "$1" in
    --template-copier)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --template-copier needs a path" >&2
            exit 2
        }
        template_copier="$2"
        shift 2
        ;;
    --recorded)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --recorded needs a path or 'none'" >&2
            exit 2
        }
        recorded="$2"
        shift 2
        ;;
    --data-file)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --data-file needs a path" >&2
            exit 2
        }
        data_file="$2"
        shift 2
        ;;
    --active-keys)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --active-keys needs a path" >&2
            exit 2
        }
        active_keys="$2"
        shift 2
        ;;
    --template-commit)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --template-commit needs a sha" >&2
            exit 2
        }
        template_commit="$2"
        shift 2
        ;;
    --state-dir)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --state-dir needs a directory" >&2
            exit 2
        }
        state_dir="$2"
        shift 2
        ;;
    --confirm)
        [ "$mode" = check ] && {
            usage
            echo "FAIL: --confirm and --check are exclusive" >&2
            exit 2
        }
        mode="confirm"
        shift
        ;;
    --check)
        [ "$mode" = confirm ] && {
            usage
            echo "FAIL: --confirm and --check are exclusive" >&2
            exit 2
        }
        mode="check"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        echo "FAIL: unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

command -v git >/dev/null 2>&1 || {
    echo "FAIL: git is required" >&2
    exit 2
}
[ -n "$data_file" ] || {
    usage
    echo "FAIL: --data-file is required" >&2
    exit 2
}
[ -f "$data_file" ] || {
    echo "FAIL: no such data file: $data_file" >&2
    exit 2
}

marker_name="answers-confirmed"

# ── --check ────────────────────────────────────────────────────────────
not_confirmed() {
    echo "FAIL: resolved answers not confirmed; rerun confirm-answers.sh, present the set, obtain explicit approval, then --confirm" >&2
    echo "  reason: $1" >&2
    exit 1
}

if [ "$mode" = check ]; then
    [ -n "$state_dir" ] || {
        usage
        echo "FAIL: --check requires --state-dir" >&2
        exit 2
    }
    marker="$state_dir/$marker_name"
    [ -f "$marker" ] || not_confirmed "no confirmation marker at $marker"
    recorded_oid="$(awk '$1 == "data-file-oid" { print $2 }' "$marker")"
    recorded_commit="$(awk '$1 == "template-commit" { print $2 }' "$marker")"
    current_oid="$(git hash-object "$data_file")"
    [ -n "$recorded_oid" ] || not_confirmed "marker records no data-file OID"
    [ "$recorded_oid" = "$current_oid" ] ||
        not_confirmed "the data file changed after confirmation ($recorded_oid -> $current_oid)"
    if [ -n "$template_commit" ]; then
        [ "$recorded_commit" = "$template_commit" ] ||
            not_confirmed "the template commit changed after confirmation ($recorded_commit -> $template_commit)"
    fi
    echo "confirmed: $data_file ($current_oid) against template commit ${recorded_commit:-<unrecorded>}"
    exit 0
fi

# ── print / --confirm ──────────────────────────────────────────────────
command -v yq >/dev/null 2>&1 || {
    echo "FAIL: yq (v4) is required" >&2
    exit 2
}
[ -n "$template_copier" ] || {
    usage
    echo "FAIL: --template-copier is required" >&2
    exit 2
}
[ -f "$template_copier" ] || {
    echo "FAIL: no such copier.yml: $template_copier" >&2
    exit 2
}
[ -n "$recorded" ] || {
    usage
    echo "FAIL: --recorded is required (a path, or 'none')" >&2
    exit 2
}
if [ "$recorded" != none ] && [ ! -f "$recorded" ]; then
    echo "FAIL: no such recorded answers file: $recorded (pass 'none' when there is none)" >&2
    exit 2
fi
if [ -n "$active_keys" ] && [ ! -f "$active_keys" ]; then
    echo "FAIL: no such active-keys file: $active_keys" >&2
    exit 2
fi
if [ "$mode" = confirm ]; then
    [ -n "$state_dir" ] || {
        usage
        echo "FAIL: --confirm requires --state-dir" >&2
        exit 2
    }
    [ -d "$state_dir" ] || {
        echo "FAIL: no such state directory: $state_dir" >&2
        exit 2
    }
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# key <TAB> default-json <TAB> help-json <TAB> has-when <TAB> has-default
yq -r '
  to_entries | .[] | select(.key | test("^_") | not) |
  .key + "\t" + (.value.default | @json) + "\t" + (.value.help | @json) +
  "\t" + (.value | has("when") | tostring) +
  "\t" + (.value | has("default") | tostring)' \
    "$template_copier" >"$work/template.tsv" ||
    {
        echo "FAIL: could not read questions from $template_copier" >&2
        exit 2
    }

yq -r 'to_entries | .[] | .key + "\t" + (.value | @json)' "$data_file" \
    >"$work/data.tsv" ||
    {
        echo "FAIL: could not read $data_file" >&2
        exit 2
    }

: >"$work/recorded.tsv"
if [ "$recorded" != none ]; then
    yq -r 'to_entries | .[] | select(.key | test("^_") | not) |
      .key + "\t" + (.value | @json)' "$recorded" >"$work/recorded.tsv" ||
        {
            echo "FAIL: could not read $recorded" >&2
            exit 2
        }
fi

# Questions copier itself marks secret are never printed as values.
yq -r '._secret_questions // [] | .[]' "$template_copier" >"$work/secret-keys" ||
    : >"$work/secret-keys"

if [ -n "$active_keys" ]; then
    grep -v '^[[:space:]]*$' "$active_keys" >"$work/keys" || : >"$work/keys"
else
    cut -f1 "$work/template.tsv" >"$work/keys"
fi

field() { # file key column -> value ("" when absent)
    awk -F '\t' -v k="$2" -v c="$3" '$1 == k { print $c; exit }' "$1"
}
has_key() {
    awk -F '\t' -v k="$2" '$1 == k { found = 1; exit } END { exit found ? 0 : 1 }' "$1"
}
is_listed_sensitive() {
    printf '%s' "$SENSITIVE_KEYS" | grep -qxF "$1"
}

: >"$work/changed"
: >"$work/new"
: >"$work/sensitive"

echo "Resolved copier answers — review every row before any \`copier … --trust\` run"
echo "  template copier.yml : $template_copier"
echo "  template commit     : ${template_commit:-<unspecified>}"
echo "  data file           : $data_file ($(git hash-object "$data_file"))"
echo "  recorded answers    : $recorded"
if [ -n "$active_keys" ]; then
    echo "  active question set : $active_keys"
else
    echo "  active question set : every non-underscore copier.yml question (unfiltered)"
fi
echo
printf '%-42s %-16s %s\n' KEY SOURCE "VALUE / FLAGS"

while IFS= read -r key; do
    [ -n "$key" ] || continue
    value=""
    source=""
    note=""
    if has_key "$work/data.tsv" "$key"; then
        value="$(field "$work/data.tsv" "$key" 2)"
        source="data-file"
    elif has_key "$work/recorded.tsv" "$key"; then
        value="$(field "$work/recorded.tsv" "$key" 2)"
        source="recorded"
    elif [ "$(field "$work/template.tsv" "$key" 5)" = true ]; then
        value="$(field "$work/template.tsv" "$key" 2)"
        source="template-default"
        case "$value" in
        *'[['* | *'[%'* | *'{{'* | *'{%'*) note="$note (templated default)" ;;
        esac
    else
        value="<no default — copier will prompt or fail>"
        source="unanswered"
    fi

    flags=""
    if [ "$recorded" = none ] || ! has_key "$work/recorded.tsv" "$key"; then
        flags="$flags NEW"
        printf '%s\n' "$key" >>"$work/new"
    elif [ "$value" != "$(field "$work/recorded.tsv" "$key" 2)" ]; then
        flags="$flags CHANGED"
        printf '%s\n' "$key" >>"$work/changed"
    fi
    help_json="$(field "$work/template.tsv" "$key" 3)"
    if is_listed_sensitive "$key" ||
        printf '%s' "$help_json" | grep -Eqi "$SENSITIVE_HELP_RE"; then
        flags="$flags SENSITIVE"
        printf '%s\n' "$key" >>"$work/sensitive"
    fi
    if [ -z "$active_keys" ] && [ "$(field "$work/template.tsv" "$key" 4)" = true ]; then
        note="$note (may be inactive — \`when:\`-gated)"
    fi
    if grep -qxF "$key" "$work/secret-keys" 2>/dev/null; then
        value="<secret>"
    fi

    printf '%-42s %-16s %s%s%s\n' "$key" "$source" "$value" "$flags" "$note"
done <"$work/keys"

print_block() { # title file
    echo
    if [ -s "$2" ]; then
        echo "== $1 =="
        sed 's/^/  - /' "$2"
    else
        echo "== $1 == (none)"
    fi
}
print_block "CHANGED (differs from the recorded .copier-answers.yml)" "$work/changed"
print_block "NEW (no recorded value — includes questions the template just added)" "$work/new"
print_block "SENSITIVE (grants trust, names principals, or has a side effect)" "$work/sensitive"

cat <<'NOTE'

The next step executes the template's `_tasks` under `--trust`. Claude Code
auto-mode's classifier may deny `copier update --trust` / `copier copy --trust`
for exactly that reason; the earlier `--skip-tasks` discovery/audit renders are
denied by the same classifier. THIS is the checkpoint where you either approve
the run when prompted, or add a `Bash(copier update:*)` / `Bash(copier copy:*)`
permission rule yourself. Agents never self-grant permissions, and a parallel
worker never confirms on your behalf: it prints this set, stops, and returns it.
NOTE

if [ "$mode" = confirm ]; then
    marker="$state_dir/$marker_name"
    candidate="$(mktemp "$state_dir/$marker_name.XXXXXX")" ||
        {
            echo "FAIL: could not create the confirmation marker" >&2
            exit 1
        }
    if {
        printf 'data-file-oid %s\n' "$(git hash-object "$data_file")"
        printf 'template-commit %s\n' "$template_commit"
    } >"$candidate"; then
        mv "$candidate" "$marker" || {
            rm -f "$candidate"
            echo "FAIL: could not publish the confirmation marker" >&2
            exit 1
        }
    else
        rm -f "$candidate"
        echo "FAIL: could not record the confirmation" >&2
        exit 1
    fi
    echo
    echo "confirmation recorded: $marker"
else
    echo
    echo "NOT confirmed: rerun with --confirm --state-dir <dir> only after explicit approval."
fi
