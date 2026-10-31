#!/usr/bin/env bash
# Derive test and validator dependencies from path tokens; unreadable fences refuse.
set -euo pipefail

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo 'validator-dependency-scan: not inside a Git worktree' >&2
    exit 1
}
python3 - "$repo" "$@" <<'PYTHON'
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

repo = os.path.realpath(sys.argv[1])
parser = argparse.ArgumentParser(description='Find fenced test and validator dependencies by path token')
parser.add_argument('--check-plan')
parser.add_argument('--lane')
parser.add_argument('--waive', action='append', default=[])
parser.add_argument('paths', nargs='*')
args = parser.parse_args(sys.argv[2:])
if args.check_plan:
    if args.paths:
        parser.error('positional paths cannot be combined with --check-plan')
elif not args.paths or args.lane or args.waive:
    parser.error('supply paths or --check-plan')

def fail(message):
    print('validator-dependency-scan: ' + message, file=sys.stderr)
    sys.exit(1)

def canonical(path):
    return (isinstance(path, str) and bool(path) and not path.startswith('/')
            and all(part not in ('', '.', '..') for part in path.split('/'))
            and '\n' not in path and '\r' not in path)

def matches(pattern, path):
    # Same component and ** semantics as fence-check.sh.
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

def classified(path):
    parts = path.split('/')
    name = parts[-1]
    stem, ext = os.path.splitext(name)
    if ext not in ('.sh', '.py', '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs'):
        return False
    return (any(part in ('tests', 'test', '__tests__') for part in parts[:-1])
            or stem.startswith(('test_', 'test-', 'validate-', 'lint-'))
            or stem.endswith(('_test', '.test', '.spec')))

def read_text(path):
    full = os.path.join(repo, path)
    try:
        if not os.path.lexists(full):
            return None, 'missing or planned path'
        resolved = os.path.realpath(full)
        if os.path.commonpath((repo, resolved)) != repo:
            return None, 'symlink resolves outside repository'
        if os.path.isdir(resolved):
            return None, 'directory, not a regular file'
        if not os.path.isfile(resolved):
            return None, 'dangling symlink or not a regular file'
        with open(resolved, 'rb') as handle:
            data = handle.read()
        if b'\0' in data:
            return None, 'binary or NUL bytes'
        return data.decode('utf-8'), None
    except UnicodeDecodeError:
        return None, 'not UTF-8 text'
    except OSError as error:
        return None, 'unreadable: ' + str(error)

# Delimiters separate paths from shell, Markdown and structured-data syntax.
token_re = re.compile(r'''[^\s"'=:\(\),;|&`<>{}\[\]]+''')
def uncomment(text):
    # Keep quoted paths and URLs intact while dropping actual line comments.
    lines = []
    for line in text.splitlines():
        quote = None
        escaped = False
        for i, char in enumerate(line):
            if escaped:
                escaped = False
                continue
            if char == '\\' and quote != "'":
                escaped = True
                continue
            if quote:
                if char == quote:
                    quote = None
                continue
            if char in ("'", '"'):
                quote = char
            elif (char == '#' or line[i:i+2] == '//') and (i == 0 or line[i-1].isspace()):
                line = line[:i]
                break
        lines.append(line)
    return '\n'.join(lines)

def references(text, owner, known, forward=False, glob_targets=None):
    result = set()
    text = uncomment(text)
    if forward and classified(owner):
        # A test asserting Taskfile wiring does not invoke the asserted target.
        text = '\n'.join(line for line in text.replace('\\\n', ' ').splitlines()
                         if not (re.search(r'\bgrep\b', line) and 'Taskfile.yml' in line))
    for token in token_re.findall(text):
        token = token.rstrip('.')
        candidates = []
        for base in ('', os.path.dirname(owner)):
            candidate = os.path.normpath(os.path.join(base, token)).replace(os.sep, '/')
            if canonical(candidate) and candidate in known:
                candidates.append(candidate)
        # Variable prefixes cannot be expanded statically. Compare complete path
        # components and choose the longest known suffix, never a substring.
        components = token.split('/')
        for i in range(len(components)):
            suffix = '/'.join(components[i:])
            if canonical(suffix) and suffix in known:
                candidates.append(suffix)
        if candidates:
            result.add(max(candidates, key=lambda value: (len(value.split('/')), len(value))))
        if ('*' in token or '?' in token) and '/' in token:
            for i in range(len(components)):
                pattern = '/'.join(components[i:])
                parts = pattern.split('/')
                # Only a concrete directory and a file pattern identify a useful
                # dependency; generic policy globs like **/*.md are not calls.
                if (len(parts) > 1 and canonical(pattern)
                        and not any('*' in part or '?' in part for part in parts[:-1])
                        and len(re.sub(r'[^A-Za-z0-9]', '', parts[-1])) >= 2):
                    result.update(path for path in (known if glob_targets is None else glob_targets) if matches(pattern, path))
    return result

def path_of(entry):
    return entry if isinstance(entry, str) else entry['path']

try:
    raw = subprocess.check_output(['git', '-C', repo, 'ls-files', '-z', '--cached'])
    tracked = {os.fsdecode(path) for path in raw.split(b'\0') if path}
    if args.check_plan:
        with open(args.check_plan, encoding='utf-8') as handle:
            revisions = json.load(handle)['revisions']
        plan = revisions[-1]['plan']
        lanes = plan['lanes']
        if not isinstance(lanes, list) or not lanes:
            raise ValueError('missing lanes')
        lanes = [lane for lane in lanes if not args.lane or lane.get('lane') == args.lane]
        if not lanes:
            raise ValueError('lane not found: ' + str(args.lane))
    else:
        revisions = []
        plan = {'policy': {}}
        for path in args.paths:
            if os.path.isabs(path) and os.path.commonpath((repo, os.path.abspath(path))) != repo:
                raise ValueError('absolute path outside repository: ' + path)
        paths = [os.path.relpath(path, repo) if os.path.isabs(path) else path for path in args.paths]
        lanes = [{'lane': 'scan', 'fence': paths, 'expansions': []}]
    if any(not canonical(path) for path in args.waive):
        raise ValueError('invalid --waive path')
except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.CalledProcessError) as error:
    fail('cannot read plan or repository: ' + str(error))

missing = False
for lane in lanes:
    try:
        lane_id = lane['lane']
        expansions = lane['expansions']
        fence = [path_of(item) for item in lane['fence'] + expansions]
        for path in fence:
            if isinstance(path, str) and os.path.isabs(path) and os.path.commonpath((repo, os.path.abspath(path))) != repo:
                raise ValueError('absolute path outside repository: ' + path)
        if not isinstance(lane_id, str) or not lane_id or not fence or any(not canonical(path) for path in fence):
            raise ValueError('invalid lane or fence')
        literal = {path for path in fence if '*' not in path and '?' not in path}
        known = tracked | literal
        sources = sorted(path for path in known if any(matches(pattern, path) for pattern in fence))
        recorded = {entry['path'] for entry in expansions if entry.get('at') and entry.get('reason')}
        profile = next((entry['policy'] for entry in plan.get('lane_profiles', []) if entry['lane'] == lane_id), plan.get('policy', {}))
        records = []
        if revisions and revisions[-1].get('at'):
            records.extend(plan.get('policy', {}).get('operator_pins', []))
            records.extend(profile.get('operator_pins', []))
        if revisions and revisions[-1].get('at'):
            records.append(revisions[-1]['reason'])
        for record in records:
            if not isinstance(record, str):
                raise ValueError('invalid waiver record')
            for line in record.splitlines():
                match = re.fullmatch(r'\s*fence-waiver:\s+(?:(\S+)\s+)?(\S+?):\s+(\S.*?)\s*', line)
                if match and (match.group(1) is None or match.group(1) == lane_id):
                    if not canonical(match.group(2)):
                        raise ValueError('invalid waiver path')
                    recorded.add(match.group(2))
    except (KeyError, TypeError, ValueError) as error:
        fail('invalid lane: ' + str(error))

    for pattern in fence:
        if ('*' in pattern or '?' in pattern) and not any(matches(pattern, path) for path in known):
            if pattern not in recorded:
                print(f'{lane_id}: incomplete: {pattern}: glob matches no tracked or fenced path', file=sys.stderr)
                missing = True

    source_text = {}
    for source in sources:
        text, error = read_text(source)
        if error:
            if source not in recorded:
                print(f'{lane_id}: incomplete: {source}: {error}', file=sys.stderr)
                missing = True
        else:
            source_text[source] = text

    candidates = {}
    def add(path, reason):
        candidates.setdefault(path, set()).add(reason)
    for source, text in source_text.items():
        for path in references(text, source, known, forward=True, glob_targets={path for path in known if classified(path)}):
            if path != source and classified(path):
                add(path, 'path token in ' + source)

    # Every tracked text file can consume a fenced source.
    source_set = set(sources)
    for candidate in sorted(path for path in tracked if path not in source_set):
        text, error = read_text(candidate)
        if error:
            # A binary test can still contain an identifiable path token.
            # Do not interpret it as text unless its bytes can be decoded.
            if error != 'binary or NUL bytes' or not classified(candidate):
                continue
            try:
                with open(os.path.join(repo, candidate), 'rb') as handle:
                    text = handle.read().replace(b'\0', b' ').decode('utf-8')
            except (OSError, UnicodeDecodeError):
                continue
        for source in references(text, candidate, known, glob_targets=source_set) & source_set:
            add(candidate, 'path token naming ' + source)

    for path, reasons in sorted(candidates.items()):
        covered = any(matches(pattern, path) for pattern in fence) or path in recorded or path in args.waive
        if args.check_plan:
            print(f'{lane_id}: {"covered" if covered else "missing"}: {path}: {"; ".join(sorted(reasons))}')
        else:
            print(path)
        missing |= not covered and bool(args.check_plan)
sys.exit(1 if missing else 0)
PYTHON
