#!/usr/bin/env bash
# Find consumers naming a file or its hard-coded keys; YAML/TOML scalar values are out of scope.
set -euo pipefail

usage() {
    echo "usage: validator-dependency-scan.sh <path>... | --check-plan <plan.json> [--lane <id>] [--waive <path>]..." >&2
    exit 2
}

[ "$#" -gt 0 ] || usage

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "validator-dependency-scan: not inside a Git worktree" >&2
    exit 1
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/validator-dependency-scan.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

# Check the latest plan revision; retain positional scanning for manifests.
if [ "$1" = --check-plan ]; then
    python3 - "$repo" "$0" "$@" <<'PYTHON'
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import PurePosixPath

repo, scanner, *args = sys.argv[1:]
parser = argparse.ArgumentParser()
parser.add_argument('--check-plan', required=True)
parser.add_argument('--lane')
parser.add_argument('--waive', action='append', default=[])
opts = parser.parse_args(args)

def fail(message):
    print('validator-dependency-scan: ' + message, file=sys.stderr)
    sys.exit(1)

def canonical(path):
    return (isinstance(path, str) and bool(path) and not path.startswith('/')
            and all(part not in ('', '.', '..') for part in path.split('/'))
            and '\n' not in path and '\r' not in path)

def matches(pattern, path):
    # Match fence-check.sh's component-local * and ?, recursive **, and
    # literal bracket expressions unless a component also has * or ?.
    def parts(pattern, value):
        if not pattern:
            return not value
        if pattern[0] == '**':
            return parts(pattern[1:], value) or bool(value) and parts(pattern, value[1:])
        if not value:
            return False
        component = pattern[0]
        ok = fnmatch.fnmatchcase(value[0], component) if '*' in component or '?' in component else value[0] == component
        return ok and parts(pattern[1:], value[1:])
    return parts(pattern.split('/'), path.split('/'))

try:
    with open(opts.check_plan, encoding='utf-8') as handle:
        document = json.load(handle)
    revisions = document['revisions']
    current = revisions[-1]['plan']
    lanes = current['lanes']
    if not isinstance(lanes, list) or not lanes:
        raise ValueError('missing lanes')
    raw = subprocess.check_output(['git', '-C', repo, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    files = sorted(set(os.fsdecode(p) for p in raw.split(b'\0') if p))
except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.CalledProcessError) as error:
    fail('cannot read plan or repository: ' + str(error))

selected = [lane for lane in lanes if not opts.lane or lane.get('lane') == opts.lane]
if not selected:
    fail('lane not found: ' + str(opts.lane))
if any(not canonical(p) for p in opts.waive):
    fail('invalid --waive path')

# An unreadable file is an error, never evidence of no consumer.
contents = {}
for path in files:
    full = os.path.join(repo, path)
    if not os.path.isfile(full) or os.path.islink(full):
        continue
    try:
        with open(full, 'rb') as handle:
            data = handle.read()
        if b'\0' not in data:
            contents[path] = data.decode('utf-8', errors='replace')
    except OSError as error:
        fail('cannot read ' + path + ': ' + str(error))

import_re = re.compile(r'''(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*|(?:^|[;\n])\s*(?:source|\.)\s+)["']([^"']+)["']''', re.MULTILINE)
shell_import_re = re.compile(r'(?:^|[;\n])\s*(?:source|\.)\s+([^\s;#\"\']+)', re.MULTILINE)
export_re = re.compile(r'\bexport\s+(?:default\s+)?(?:async\s+)?(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)')
def imports(text, source, importer):
    for spec in import_re.findall(text) + shell_import_re.findall(text):
        spec = spec.split('?', 1)[0]
        if spec.startswith('.'):
            resolved = os.path.normpath(os.path.join(os.path.dirname(importer), spec)).replace(os.sep, '/')
            if resolved == source or any(resolved + ext == source for ext in ('.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.sh', '.py')):
                return True
        elif spec == source:
            return True
    return False

def is_test(path):
    parts = path.split('/')
    return ((len(parts) == 2 and parts[0] == 'scripts' and parts[1].startswith('test-') and parts[1].endswith(('.sh', '.py', '.mjs')))
            or (parts[0] == 'ai' and parts[-1].startswith('test-') and parts[-1].endswith(('.sh', '.py', '.mjs'))))

def referenced(text, path):
    name = PurePosixPath(path).name
    stem = PurePosixPath(path).stem
    return path in text or name in text or (len(stem) >= 3 and re.search(r'(?<![\w-])' + re.escape(stem) + r'(?![\w-])', text) is not None)

def entry_path(entry):
    return entry if isinstance(entry, str) else entry['path']

missing = False
for lane in selected:
    try:
        lane_id = lane['lane']
        fence = [entry_path(e) for e in lane['fence'] + lane['expansions']]
        if not isinstance(lane_id, str) or not lane_id or not fence or any(not canonical(p) for p in fence):
            raise ValueError('invalid lane or fence')
        policy = current['policy']
        profile = next((p['policy'] for p in current.get('lane_profiles', []) if p['lane'] == lane_id), policy)
        records = list(policy.get('operator_pins', [])) + list(profile.get('operator_pins', [])) + [r['reason'] for r in revisions]
        waived = set(opts.waive)
        for record in records:
            if not isinstance(record, str):
                raise ValueError('invalid waiver record')
            for line in record.splitlines():
                match = re.fullmatch(r'\s*fence-waiver:\s+(?:(\S+)\s+)?([^\s:]+):\s*(\S.*?)\s*', line)
                if match and (match.group(1) is None or match.group(1) == lane_id):
                    if not canonical(match.group(2)):
                        raise ValueError('invalid waiver path')
                    waived.add(match.group(2))
    except (KeyError, TypeError, ValueError) as error:
        fail('invalid lane: ' + str(error))
    sources = sorted(path for path in contents if any(matches(f, path) for f in fence))
    candidates = {}
    def add(path, reason):
        candidates.setdefault(path, set()).add(reason)
    for source in sources:
        if source.endswith(('.json', '.yaml', '.yml', '.toml')):
            try:
                result = subprocess.run([scanner, source], cwd=repo, check=True, text=True, stdout=subprocess.PIPE)
            except (OSError, subprocess.CalledProcessError) as error:
                fail('consumer scan failed for ' + source + ': ' + str(error))
            for candidate in result.stdout.splitlines():
                add(candidate, 'validator/consumer of ' + source)
        importers = [path for path, text in contents.items() if path != source and imports(text, source, path)]
        for importer in importers:
            add(importer, 'imports ' + source)
        for path, text in contents.items():
            if is_test(path) and path != source:
                for target in [source] + importers:
                    exports = export_re.findall(contents[target])
                    named = any(re.search(r'(?<![\w$])' + re.escape(name) + r'(?![\w$])', text) for name in exports)
                    if path != target and (referenced(text, target) or named):
                        add(path, 'test references ' + target)
    for path, reasons in sorted(candidates.items()):
        covered = any(matches(f, path) for f in fence) or path in waived
        print(f'{lane_id}: {"covered" if covered else "missing"}: {path}: {"; ".join(sorted(reasons))}')
        missing |= not covered
sys.exit(1 if missing else 0)
PYTHON
    exit $?
fi

terms="$scratch/terms"
matches="$scratch/matches"
: >"$matches"

scan_root() {
    root="$1"
    recursive="$2"
    [ -e "$root" ] || return 0
    if [ "$recursive" = true ]; then
        if grep -rFwl -f "$terms" "$root"; then
            return 0
        else
            status="$?"
        fi
    else
        if grep -Fwl -f "$terms" "$root"; then
            return 0
        else
            status="$?"
        fi
    fi
    case "$status" in
    0 | 1) return 0 ;;
    *)
        echo "validator-dependency-scan: grep failed for $root (exit $status)" >&2
        return "$status"
        ;;
    esac
}

for supplied in "$@"; do
    case "$supplied" in
    /*) target="$supplied" ;;
    *) target="$repo/$supplied" ;;
    esac
    [ -f "$target" ] || {
        echo "validator-dependency-scan: target is not a file: $supplied" >&2
        exit 1
    }

    relative="${target#"$repo"/}"
    {
        printf '%s\n' "$relative" "$(basename "$relative")"
        case "$target" in
        *.json)
            jq -r '
              .. | objects | keys[]
              | select(length <= 80)
              | select(test("^[A-Za-z][A-Za-z0-9_.:-]*$"))
            ' "$target"
            jq -r '
              .. | objects | .enum? | select(type == "array")[] | strings
              | select(length <= 80)
              | select(test("^[A-Za-z][A-Za-z0-9_.:-]*$"))
            ' "$target"
            ;;
        *.yaml | *.yml)
            # Bare keys accept the full [A-Za-z0-9_-] leading charset, with
            # dots and colons allowed inside (so a `group:action`-style key,
            # this repo's own Taskfile convention, is emitted in full rather
            # than dropped — challenge round 2, confirmed); a "quoted" or
            # 'quoted' key emits its unquoted term. Each alternative mutates
            # the matched line on success, so a line matching one never also
            # matches another — except a quoted key ending in `:` (allowed
            # since `:` is in the interior charset), whose successful
            # substitution leaves the pattern space holding just the
            # unquoted term (e.g. "foo:"), which the bare-key alternative
            # can then re-match on ITS OWN trailing colon and re-emit a
            # truncated, unrelated term ("foo"). The `t` after each quoted
            # alternative branches past the rest of the script once that
            # alternative has already matched, so a successful quoted-key
            # substitution is never re-parsed (integration cycle 2,
            # confirmed). The mapping separator must actually look like
            # YAML (`:` then whitespace or end of line) rather than `.*`, or
            # a digit/hyphen-leading unquoted scalar containing a colon (a
            # Docker port mapping like "- 8080:80") is misread as a key
            # (challenge round 1, confirmed).
            sed -nE \
                -e 's/^[[:space:]]*(-[[:space:]]+)?"([A-Za-z0-9_-][A-Za-z0-9_.:-]{0,79})"[[:space:]]*:([[:space:]].*)?$/\2/p' \
                -e t \
                -e 's/^[[:space:]]*(-[[:space:]]+)?'"'"'([A-Za-z0-9_-][A-Za-z0-9_.:-]{0,79})'"'"'[[:space:]]*:([[:space:]].*)?$/\2/p' \
                -e t \
                -e 's/^[[:space:]]*(-[[:space:]]+)?([A-Za-z0-9_-][A-Za-z0-9_.:-]{0,79})[[:space:]]*:([[:space:]].*)?$/\2/p' \
                "$target"
            ;;
        *.toml)
            # `:` is allowed in the interior charset of the two QUOTED
            # alternatives only (a quoted TOML key like "group:action" is
            # valid TOML and this repo's own Taskfile convention), never the
            # bare-key alternative — an unquoted TOML key cannot contain `:`
            # (integration cycle 3, confirmed).
            sed -nE \
                -e 's/^[[:space:]]*"([A-Za-z0-9_-][A-Za-z0-9_.:-]{0,79})"[[:space:]]*=.*/\1/p' \
                -e 's/^[[:space:]]*'"'"'([A-Za-z0-9_-][A-Za-z0-9_.:-]{0,79})'"'"'[[:space:]]*=.*/\1/p' \
                -e 's/^[[:space:]]*([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})[[:space:]]*=.*/\1/p' \
                "$target"
            ;;
        esac
    } | while IFS= read -r term; do
        [ -n "$term" ] || continue
        printf '%s\n' "$term"
        printf '%s\n' "$term" | tr '_' '-'
    done | LC_ALL=C sort -u >"$terms"

    {
        scan_root "$repo/scripts" true
        scan_root "$repo/ai/skills" true
        scan_root "$repo/.agents/skills" true
        scan_root "$repo/.claude/skills" true
        scan_root "$repo/taskfiles" true
        scan_root "$repo/Taskfile.yml" false
    } | while IFS= read -r candidate; do
        [ "$candidate" != "$target" ] || continue
        relative_candidate="${candidate#"$repo"/}"
        case "$relative_candidate" in
        scripts/* | taskfiles/* | Taskfile.yml | ai/skills/*/assets/* | .agents/skills/*/assets/* | .claude/skills/*/assets/*)
            printf '%s\n' "$relative_candidate" >>"$matches"
            ;;
        esac
    done
done

LC_ALL=C sort -u "$matches"
