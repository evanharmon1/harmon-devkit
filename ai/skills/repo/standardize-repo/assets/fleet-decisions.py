#!/usr/bin/env python3
"""Validate fleet decisions and resolve explicit lane citations; never write data.

Requires Python 3.9+ and Mike Farah yq v4. The shipped JSON Schema is the
structural source of truth. Only its small keyword vocabulary is implemented;
unknown keywords fail closed instead of silently weakening validation.
"""

import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys


class Invalid(ValueError):
    """Invalid decisions, schema, or lane citation."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid(f"duplicate mapping key: {key}")
        result[key] = value
    return result


def validate(value, schema, path='$'):
    """Evaluate exactly the vocabulary used by fleet-decisions.schema.json."""
    supported = {'$schema', '$id', 'title', 'type', 'const', 'enum', 'pattern',
                 'minLength', 'required', 'properties', 'additionalProperties',
                 'items', 'oneOf'}
    if set(schema) - supported:
        raise Invalid(f"{path}: unsupported schema keywords: {set(schema) - supported}")
    if 'oneOf' in schema:
        matches = 0
        for option in schema['oneOf']:
            try:
                validate(value, option, path)
                matches += 1
            except Invalid:
                pass
        if matches != 1:
            raise Invalid(f"{path}: expected exactly one scope variant")
    kinds = {'object': dict, 'array': list, 'string': str}
    if 'type' in schema and not isinstance(value, kinds[schema['type']]):
        raise Invalid(f"{path}: expected {schema['type']}")
    if 'const' in schema and (type(value) is not type(schema['const']) or value != schema['const']):
        raise Invalid(f"{path}: expected {schema['const']!r}")
    if 'enum' in schema and value not in schema['enum']:
        raise Invalid(f"{path}: invalid enum value")
    if isinstance(value, str):
        if len(value) < schema.get('minLength', 0):
            raise Invalid(f"{path}: empty string")
        if 'pattern' in schema:
            pattern = schema['pattern']
            match = re.fullmatch if pattern.startswith('^') and pattern.endswith('$') else re.search
            if not match(pattern, value):
                raise Invalid(f"{path}: invalid string")
    if isinstance(value, dict):
        missing = set(schema.get('required', [])) - value.keys()
        if missing:
            raise Invalid(f"{path}: missing keys: {', '.join(sorted(missing))}")
        for key, child in value.items():
            rule = schema.get('properties', {}).get(key, schema.get('additionalProperties', True))
            if rule is False:
                raise Invalid(f"{path}.{key}: unknown key")
            if isinstance(rule, dict):
                validate(child, rule, f'{path}.{key}')
    if isinstance(value, list) and 'items' in schema:
        for index, child in enumerate(value):
            validate(child, schema['items'], f'{path}[{index}]')


def load(path):
    # yq parses YAML; JSON's object hook rejects duplicate keys in its output.
    version = subprocess.run(['yq', '--version'], check=True, capture_output=True, text=True)
    if 'github.com/mikefarah/yq/' not in version.stdout or 'version v4.' not in version.stdout:
        raise Invalid('Mike Farah yq v4 is required')
    parsed = subprocess.run(['yq', '-o=json', '-I=0', '.', str(path)],
                            check=True, capture_output=True, text=True)
    data = json.loads(parsed.stdout, object_pairs_hook=unique_object)
    schema = json.loads(Path(__file__).with_name('fleet-decisions.schema.json').read_text())
    validate(data, schema)
    seen = {}
    groups = [(None, data['fleet']), *data['releases'].items()]
    for release, entries in groups:
        if release is not None and (not release.strip() or release != release.strip()):
            raise Invalid('release keys must be nonempty and have no surrounding whitespace')
        for entry in entries:
            entry_id = entry['id']
            if entry_id in seen:
                raise Invalid(f'duplicate decision ID: {entry_id}')
            try:
                datetime.date.fromisoformat(entry['approved_on'])
            except ValueError as error:
                raise Invalid(f'{entry_id}: invalid approval date') from error
            seen[entry_id] = (release, entry)
    return seen, set(data['releases'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--release')
    parser.add_argument('--repository')
    parser.add_argument('--require', action='append', default=[], metavar='ID')
    args = parser.parse_args()
    if args.require and (not args.release or not args.repository):
        parser.error('--require needs --release and --repository')
    try:
        decisions, releases = load(args.file)
        if args.release is not None:
            # Even a fleet-only citation cannot substitute for a missing release.
            if args.release not in releases:
                raise Invalid(f'missing release rulings: releases.{args.release}')
        selected = []
        for entry_id in args.require:
            if entry_id not in decisions:
                raise Invalid(f'missing ruling ID: {entry_id}')
            release, entry = decisions[entry_id]
            if release is not None and release != args.release:
                raise Invalid(f'{entry_id}: ruling belongs to release {release}')
            if entry['scope'] == 'repository' and entry['repository'].lower() != args.repository.lower():
                raise Invalid(f'{entry_id}: ruling belongs to repository {entry["repository"]}')
            selected.append(entry)
        print(json.dumps({'schema_version': 1, 'decisions': selected}, indent=2))
        return 0
    except (Invalid, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'fleet-decisions: {args.file}: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
