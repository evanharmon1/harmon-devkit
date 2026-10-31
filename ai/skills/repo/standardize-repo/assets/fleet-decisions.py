#!/usr/bin/env python3
"""Validate fleet decisions, collect parent-owned run answers and bind lane rulings.

Requires Python 3.9+ and Mike Farah yq v4. The shipped JSON Schema is the
structural source of truth. Only its small keyword vocabulary is implemented;
unknown keywords fail closed instead of silently weakening validation.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid


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


def read_yaml(path):
    # yq parses YAML; JSON's object hook rejects duplicate keys in its output.
    version = subprocess.run(['yq', '--version'], check=True, capture_output=True, text=True)
    if 'github.com/mikefarah/yq/' not in version.stdout or 'version v4.' not in version.stdout:
        raise Invalid('Mike Farah yq v4 is required')
    parsed = subprocess.run(['yq', '-o=json', '-I=0', '.', str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(parsed.stdout, object_pairs_hook=unique_object)


def load(path):
    data = read_yaml(path)
    decisions_index(data)
    return data


def decisions_index(data):
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
            structured_ruling(entry, release)
            seen[entry_id] = (release, entry)
    for entry_id, (_, entry) in seen.items():
        for superseded_id in entry.get('supersedes', []):
            if superseded_id not in seen:
                raise Invalid(f'{entry_id}: supersedes missing ruling ID: {superseded_id}')

    # Three-color DFS distinguishes an actual cycle from converging histories.
    states = {}

    def visit(entry_id):
        if states.get(entry_id) == 'active':
            raise Invalid(f'supersession cycle involving {entry_id}')
        if states.get(entry_id) == 'done':
            return
        states[entry_id] = 'active'
        for superseded_id in seen[entry_id][1].get('supersedes', []):
            visit(superseded_id)
        states[entry_id] = 'done'

    for entry_id in seen:
        visit(entry_id)

    replacements = {}
    for entry_id, (_, entry) in seen.items():
        for superseded_id in entry.get('supersedes', []):
            replacements.setdefault(superseded_id, set()).add(entry_id)
    return seen, set(data['releases']), replacements


# Logical keys are stored inside the existing v1 string ruling. IDs remain
# globally unique citations; a logical key can recur across releases/repos.
QUESTIONS = (
    ('target_release', 'Target harmon-init release?'),
    ('scope', 'Run the inventory fleet, one wave, or one repository?'),
    ('copier_answers', 'Which carried-forward Copier answers change per repository?'),
    ('reconcile_classes', 'Which agent-apply reconcile classes may the parent run?'),
    ('skills_sync', 'Open skills-sync PRs: merge-first or absorb for the whole run?'),
    ('legacy_baseline', 'Accept legacy baselines?'),
    ('guarded_rollback', 'Approve guarded rollback?'),
    ('model_rulings', 'Which model rulings apply to lanes?'),
    ('review_exclusions', 'Which additional review exclusions apply?'),
)
KEYS = {key for key, _ in QUESTIONS}


def validate_answer(key, answer, release):
    """Validate one question's answer, independent of inventory selection."""
    if key == 'target_release':
        if answer != release:
            raise Invalid('target_release must equal the enclosing release')
    elif key == 'scope':
        if not isinstance(answer, dict):
            raise Invalid('scope must be an object')
        if answer == {'kind': 'fleet'}:
            return
        if (set(answer) == {'kind', 'wave'} and answer['kind'] == 'wave'
                and type(answer['wave']) is int and answer['wave'] > 0):
            return
        if (set(answer) == {'kind', 'repository'} and answer['kind'] == 'repository'
                and isinstance(answer['repository'], str)
                and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', answer['repository'])):
            return
        raise Invalid('scope must select fleet, a positive wave or an owner/name repository')
    elif key == 'copier_answers':
        if not isinstance(answer, dict) or any(
                not isinstance(k, str) or not k.strip() or k.startswith('_') for k in answer):
            raise Invalid('copier_answers must contain public non-underscore Copier answer keys')
    elif key in ('reconcile_classes', 'review_exclusions'):
        if not isinstance(answer, list) or any(not isinstance(v, str) or not v.strip() for v in answer):
            raise Invalid(f'{key} must be a list of nonempty strings')
        if key == 'reconcile_classes' and set(answer) - {'agent-apply', 'agent-apply-with-fleet-approval'}:
            raise Invalid('reconcile_classes may only contain agent-apply classes')
    elif key == 'skills_sync':
        if answer not in ('merge-first', 'absorb'):
            raise Invalid('skills_sync must be merge-first or absorb')
    elif key in ('legacy_baseline', 'guarded_rollback'):
        if type(answer) is not bool:
            raise Invalid(f'{key} must be a boolean')
    elif key == 'model_rulings':
        if not isinstance(answer, dict):
            raise Invalid('model_rulings must be an object')


def structured_ruling(entry, release):
    """Recognize and validate reserved question payloads; retain free-form v1."""
    try:
        payload = json.loads(entry['ruling'], object_pairs_hook=unique_object)
    except (json.JSONDecodeError, Invalid, RecursionError):
        # A v1 ruling that cannot be decoded remains opaque text.
        # JSON-looking prose need not have unique keys or bounded nesting.
        return None
    if not isinstance(payload, dict):
        return None
    if 'schema_version' not in payload:
        return None
    key = payload.get('key')
    if (type(payload.get('schema_version')) is not int or payload['schema_version'] != 1
            or not isinstance(key, str) or key not in KEYS or 'answer' not in payload):
        raise Invalid(f'{entry["id"]}: invalid start-of-run ruling payload')
    expected_scope = 'repository' if key == 'copier_answers' else 'release'
    if release is None or entry['scope'] != expected_scope:
        raise Invalid(f'{entry["id"]}: {key} requires {expected_scope} scope under a release')
    validate_answer(key, payload['answer'], release)
    return payload


def ruling_by_key(data, release, key, repository=None):
    if key not in KEYS:
        raise Invalid(f'unknown ruling key: {key}')
    seen, _, replacements = decisions_index(data)
    matches = []
    for entry_id, (entry_release, entry) in seen.items():
        if entry_id in replacements or entry_release != release:
            continue
        if key == 'copier_answers':
            if entry['scope'] != 'repository' or not repository or entry['repository'].lower() != repository.lower():
                continue
        elif entry['scope'] != 'release':
            continue
        payload = structured_ruling(entry, entry_release)
        if payload is not None and payload['key'] == key:
            matches.append((entry, payload['answer']))
    label = f'{key}.{repository}' if key == 'copier_answers' else key
    if len(matches) != 1:
        raise Invalid(f'{"missing" if not matches else "conflicting"} ruling key: {label}')
    return matches[0]


def inventory_rows(path):
    inventory = read_yaml(path)
    if not isinstance(inventory, dict) or not isinstance(inventory.get('repositories'), list):
        raise Invalid('inventory projection needs a repositories list')
    rows = inventory['repositories']
    names = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('repository'), str) or not re.fullmatch(
                r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', row['repository']):
            raise Invalid('inventory repository must be owner/name')
        if type(row.get('wave')) is not int or row['wave'] < 1:
            raise Invalid(f'{row["repository"]}: inventory wave must be a positive integer')
        name = row['repository'].lower()
        if name in names:
            raise Invalid(f'duplicate inventory repository: {name}')
        names.add(name)
    if not rows:
        raise Invalid('inventory has no repositories')
    return rows


def validate_answers(answers, rows, release):
    if set(answers) != KEYS:
        raise Invalid('answers must contain exactly the fixed question keys')
    for key in KEYS - {'copier_answers'}:
        validate_answer(key, answers[key], release)
    scope = answers['scope']
    if scope == {'kind': 'fleet'}:
        selected = rows
    elif scope['kind'] == 'wave':
        selected = [row for row in rows if row['wave'] == scope['wave']]
    else:
        selected = [row for row in rows if row['repository'].lower() == scope['repository'].lower()]
    if not selected:
        raise Invalid('scope selects no inventory repositories')
    changes = answers['copier_answers']
    if not isinstance(changes, dict) or set(changes) != {row['repository'] for row in selected}:
        raise Invalid('copier_answers must name exactly the selected repositories')
    for values in changes.values():
        validate_answer('copier_answers', values, release)
    return selected


def question_answers(data, release, rows):
    answers = dict(target_release=release, scope={'kind': 'fleet'}, copier_answers={},
                   reconcile_classes=[], skills_sync='merge-first', legacy_baseline=False,
                   guarded_rollback=False, model_rulings={}, review_exclusions=[])
    for key, _ in QUESTIONS:
        if key == 'copier_answers':
            continue
        try:
            answers[key] = ruling_by_key(data, release, key)[1]
        except Invalid as error:
            if not str(error).startswith('missing ruling key:'):
                raise
    # Select repositories before filling per-repo defaults. Reuse the same
    # scope validator so a stale scope cannot silently become a fleet run.
    scope = answers['scope']
    candidates = rows
    if isinstance(scope, dict) and scope.get('kind') == 'wave':
        candidates = [r for r in rows if r['wave'] == scope.get('wave')]
    elif isinstance(scope, dict) and scope.get('kind') == 'repository':
        candidates = [r for r in rows if r['repository'].lower() == str(scope.get('repository')).lower()]
    for row in candidates:
        repo = row['repository']
        try:
            answers['copier_answers'][repo] = ruling_by_key(data, release, 'copier_answers', repo)[1]
        except Invalid as error:
            if not str(error).startswith('missing ruling key:'):
                raise
            answers['copier_answers'][repo] = {}
    validate_answers(answers, rows, release)
    return answers


def write_answers(path, data, release, answers, approver, approved_on):
    if not approver.strip():
        raise Invalid('--approved-by must be nonempty')
    datetime.date.fromisoformat(approved_on)
    seen, _, replacements = decisions_index(data)
    selected_repos = {repo.lower() for repo in answers['copier_answers']}
    deselected = []
    for entry_id, (entry_release, entry) in seen.items():
        if entry_release != release or entry_id in replacements:
            continue
        payload = structured_ruling(entry, entry_release)
        if (payload is not None and payload['key'] == 'copier_answers'
                and entry['repository'].lower() not in selected_repos):
            deselected.append(entry_id)
    for key, _ in QUESTIONS:
        values = answers[key].items() if key == 'copier_answers' else [(None, answers[key])]
        for repo, answer in values:
            entry = dict(id='RUN-' + uuid.uuid4().hex.upper(),
                         scope='repository' if repo else 'release',
                         ruling=json.dumps(dict(schema_version=1, key=key, answer=answer), sort_keys=True),
                         approved_by=approver, approved_on=approved_on)
            if repo:
                entry['repository'] = repo
            try:
                previous, _ = ruling_by_key(data, release, key, repo)
                entry['supersedes'] = [previous['id']]
            except Invalid as error:
                if not str(error).startswith('missing ruling key:'):
                    raise
            if key == 'scope' and deselected:
                # The new scope explicitly retires approvals for omitted repos.
                # Historical entries stay intact, and later expansion needs a
                # fresh repository ruling instead of resurrecting old approval.
                entry.setdefault('supersedes', []).extend(deselected)
            data['releases'].setdefault(release, []).append(entry)
    decisions_index(data)
    # JSON is valid YAML. Publish in the destination directory so a failed
    # serialization/validation never truncates the existing decisions file.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            json.dump(data, output, indent=2)
            output.write('\n')
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--release')
    parser.add_argument('--repository')
    parser.add_argument('--require', action='append', default=[], metavar='ID')
    parser.add_argument('--require-key', action='append', default=[], choices=sorted(KEYS))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--questions', action='store_true', help='render questions and reusable answers as JSON')
    mode.add_argument('--record-answers', type=Path, help='parent-only: record a complete reviewed answers object')
    parser.add_argument('--inventory', type=Path, help='inventory projection with repositories: [{repository, wave}]')
    parser.add_argument('--approved-by')
    parser.add_argument('--approved-on', default=datetime.date.today().isoformat())
    args = parser.parse_args()
    if (args.require or args.require_key) and (not args.release or not args.repository):
        parser.error('--require/--require-key needs --release and --repository')
    if (args.questions or args.record_answers) and (not args.release or not args.inventory):
        parser.error('question collection needs --release and --inventory')
    if args.record_answers and not args.approved_by:
        parser.error('--record-answers needs --approved-by after explicit maintainer approval')
    if (args.questions or args.record_answers) and (args.require or args.require_key):
        parser.error('question collection and lane requirements are exclusive')
    try:
        data = load(args.file)
        if args.questions or args.record_answers:
            rows = inventory_rows(args.inventory)
            if args.questions:
                answers = question_answers(data, args.release, rows)
                print(json.dumps(dict(schema_version=1, questions=[dict(key=k, question=q, answer=answers[k])
                                                                 for k, q in QUESTIONS], answers=answers), indent=2))
            else:
                answers = read_yaml(args.record_answers)
                if not isinstance(answers, dict):
                    raise Invalid('answers must be an object')
                validate_answers(answers, rows, args.release)
                write_answers(args.file, data, args.release, answers, args.approved_by, args.approved_on)
                print(json.dumps({'recorded_release': args.release}))
            return 0
        decisions, releases, replacements = decisions_index(data)
        if args.release is not None:
            # Even a fleet-only citation cannot substitute for a missing release.
            if args.release not in releases and not args.require_key:
                raise Invalid(f'missing release rulings: releases.{args.release}')
        selected = []
        for key in args.require_key:
            selected.append(ruling_by_key(data, args.release, key, args.repository)[0])
        for entry_id in args.require:
            if entry_id not in decisions:
                raise Invalid(f'missing ruling ID: {entry_id}')
            if entry_id in replacements:
                direct = sorted(replacements[entry_id])
                raise Invalid(f'{entry_id}: superseded by {", ".join(direct)}')
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
