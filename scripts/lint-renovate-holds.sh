#!/usr/bin/env bash
# Validate the records attached to Renovate allowedVersions rules.
set -euo pipefail
root=${1:-.}
cd "$root"
python3 - <<'PY'
import json
import pathlib
import re
import sys


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def objects(value):
    """Walk parsed JSON objects, including nested package rules."""
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def holds(path):
    """Extract JSON objects; template hold objects must be standalone JSON."""
    try:
        text = path.read_text(encoding='utf-8')
        if path.suffix != '.jinja':
            return [obj for obj in objects(json.loads(text)) if 'allowedVersions' in obj]
        # Skip complete JSON strings and Jinja tags when looking for object starts
        # and decoded keys. Every hold key must belong to a parseable object.
        tokens = re.compile(r'"(?:[^"\\]|\\.)*"|\[%.*?%\]|\[\[.*?\]\]|\{', re.S)
        decoder = json.JSONDecoder()
        found, count = [], 0
        for token in tokens.finditer(text):
            value = token.group()
            if value.startswith('"'):
                if re.match(r'\s*:', text[token.end():]) and json.loads(value) == 'allowedVersions':
                    count += 1
            elif value == '{':
                try:
                    obj, _ = decoder.raw_decode(text, token.start())
                except ValueError:
                    continue
                if isinstance(obj, dict) and 'allowedVersions' in obj:
                    found.append(obj)
        if len(found) != count:
            fail(f'{path}: cannot inspect every allowedVersions rule')
        return found
    except (OSError, ValueError) as error:
        fail(f'{path}: cannot inspect JSON: {error}')


component = r'[^\s\x00-\x1f\x7f-\x9f/;]+'
pattern = re.compile(
    r'^Reason: [^;]*[^\s;][^;]*; Upstream: https://github\.com/'
    + component + '/' + component + r'/(?:issues|pull)/[0-9]+; Remove when: '
    + r'[^;]*[^\s;][^;]*; Canary: https://github\.com/' + component + '/' + component + r'$',
    re.DOTALL,
)


def check(path, exemptions=False):
    rules = holds(path)
    for rule in rules:
        if exemptions and rule.get('matchPackageNames') in ([ 'joshmedeski/sesh' ], [ 'XAMPPRocky/tokei' ]):
            continue
        description = rule.get('description')
        if not isinstance(description, str) or not pattern.fullmatch(description):
            fail(f'{path}: allowedVersions rule needs Reason, upstream issue/PR, Remove when, and Canary')
    return rules


root = pathlib.Path('renovate.json')
preset = pathlib.Path('renovate/default.json')
template = pathlib.Path('template/renovate.json.jinja')
if not root.is_file():
    fail('renovate.json: missing')
if preset.is_file() and template.is_file():
    actual = check(root, True)
    shared = check(preset)
    templated = check(template)
    # Compare complete objects, preserving multiplicity without requiring key order.
    canonical = lambda rule: json.dumps(rule, sort_keys=True, ensure_ascii=True)
    if sorted(map(canonical, shared)) != sorted(map(canonical, templated)):
        fail('template holds differ from preset')
    if any(list(map(canonical, actual)).count(canonical(rule)) != 1 for rule in shared):
        fail('root is missing a shared hold or differs from the preset')
else:
    check(root)
PY
