#!/usr/bin/env bash
# Verify an already-tokenized gh invocation; never evaluate shell command text.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from urllib.parse import urlsplit


class Refused(Exception):
    pass


def git(root, *args):
    return subprocess.check_output(
        ['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True
    ).strip()


def canonical_repo(value):
    if value.startswith(('https://', 'http://', 'ssh://')):
        url = urlsplit(value)
        host, path = url.hostname, url.path.strip('/')
    elif ':' in value and '/' not in value.split(':', 1)[0]:
        host, path = value.split(':', 1)
        host = host.rsplit('@', 1)[-1]
    else:
        parts = value.strip('/').split('/')
        if len(parts) == 2:
            host, path = os.environ.get('GH_HOST') or 'github.com', '/'.join(parts)
        elif len(parts) == 3:
            host, path = parts[0], '/'.join(parts[1:])
        else:
            raise ValueError('repository must be [HOST/]OWNER/REPO')
    host = (host or '').lower()
    if host == 'ssh.github.com':
        host = 'github.com'
    path = path.removesuffix('.git').lower()
    if not re.fullmatch(r'[^/\s:]+/[^/\s:]+', path) or not re.fullmatch(r'[\w.-]+', host):
        raise ValueError('cannot resolve repository')
    return path if host == 'github.com' else host + '/' + path


def draft(repo, title, body, labels):
    return dict(repo=canonical_repo(repo), title=title,
                body_sha256=hashlib.sha256(body).hexdigest(),
                labels=sorted(set(label.strip() for label in labels if label.strip())))


def key(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode('utf-8')).hexdigest()


def receipt_dir(root):
    common = Path(git(root, 'rev-parse', '--git-common-dir'))
    if not common.is_absolute():
        common = Path(root) / common
    return common.resolve() / 'track-work' / 'receipts'



def verify(args, script):
    root, max_age = Path.cwd(), 3600
    while args and args[0] != '--':
        name = args.pop(0)
        if name not in ('--repo-root', '--max-age-seconds') or not args:
            raise ValueError('expected --repo-root PATH, --max-age-seconds N, then -- gh ...')
        value = args.pop(0)
        if name == '--repo-root':
            root = Path(value).resolve()
        else:
            max_age = int(value)
            if max_age < 0:
                raise ValueError('--max-age-seconds must be nonnegative')
    if not args or args.pop(0) != '--':
        raise ValueError('pass a tokenized invocation after --')
    if not args or Path(args.pop(0)).name != 'gh':
        return 3
    # Consume global flags at either command level before classifying issue argv.
    global_values = {}
    def command():
        while args:
            token = args.pop(0)
            name, separator, inline = token.partition('=')
            if name in ('-R', '--repo'):
                if not separator and not args:
                    raise ValueError('missing value for ' + name)
                value = inline if separator else args.pop(0)
                if name in ('-R', '--repo'):
                    if '--repo' in global_values:
                        raise ValueError('repeated --repo')
                    global_values['--repo'] = value
            elif token in ('-h', '--help', '--version'):
                return None
            elif token.startswith('-'):
                raise ValueError('unsupported gh global option ' + token)
            else:
                return token
        return None
    if command() != 'issue':
        return 3
    operation = command()
    if operation is None or operation in (
            'list', 'ls', 'view', 'status', 'close', 'reopen', 'comment',
            'develop', 'transfer', 'pin', 'unpin', 'lock', 'unlock', 'delete'):
        return 3
    if operation not in ('create', 'new', 'edit'):
        raise ValueError('unclassified gh issue operation ' + operation)
    if operation == 'new':
        operation = 'create'
    values, labels, positional = global_values, [], []
    field_flags = False
    aliases = {'-R': '--repo', '-t': '--title', '-b': '--body', '-F': '--body-file', '-l': '--label'}
    ignored_values = {'--assignee', '-a', '--milestone', '-m', '--project', '-p', '--type',
                      '--add-label', '--remove-label', '--add-assignee',
                      '--remove-assignee', '--add-project', '--remove-project'}
    while args:
        token = args.pop(0)
        name, separator, inline = token.partition('=')
        name = aliases.get(name, name)
        if name in ('--repo', '--title', '--body', '--body-file', '--label') or name in ignored_values:
            field_flags = field_flags or name != '--repo'
            if separator:
                value = inline
            elif args:
                value = args.pop(0)
            else:
                raise ValueError('missing value for ' + name)
            if name == '--label':
                labels.extend(value.split(','))
            elif name not in ignored_values:
                if name in values:
                    raise ValueError('repeated ' + name)
                values[name] = value
        elif token in ('-h', '--help'):
            return 3
        elif token in ('--remove-milestone',):
            field_flags = True
            continue
        elif token.startswith('-'):
            raise ValueError('unsupported or interactive gh option ' + token)
        else:
            positional.append(token)
    if operation == 'edit' and not any(n in values for n in ('--title', '--body', '--body-file')):
        if not field_flags:
            raise ValueError('field-less edit opens the interactive field picker')
        return 3
    if '--body' in values and '--body-file' in values:
        raise ValueError('choose --body or --body-file')
    if operation == 'create' and positional:
        raise ValueError('unexpected create arguments')
    if operation == 'edit' and not positional:
        raise ValueError('edit needs an issue selector')
    # URL selectors must not silently change the repository selected by argv.
    for selector in positional:
        if not re.fullmatch(r'[0-9]+', selector):
            raise ValueError('use numeric edit selectors with --repo')
    selected_repo = values.get('--repo') or os.environ.get('GH_REPO')
    if not selected_repo:
        raise Refused('specify --repo (or GH_REPO) for issue writes')
    repo = canonical_repo(selected_repo)
    title = values.get('--title')
    body = None
    if '--body' in values:
        body = values['--body'].encode('utf-8')
    elif '--body-file' in values:
        path = values['--body-file']
        if path == '-':
            raise ValueError('stdin body cannot be verified; use a regular body file')
        body = Path(path).read_bytes()
    expected = dict(repo=repo)
    if title is not None:
        expected['title'] = title
    if body is not None:
        expected['body_sha256'] = hashlib.sha256(body).hexdigest()
    if operation == 'create':
        if title is None or body is None:
            raise ValueError('create needs explicit --title and --body or --body-file')
        expected['labels'] = draft(repo, title, body, labels)['labels']
    directory = receipt_dir(root)
    triage_hint = dict(expected, labels=sorted(set(expected.get('labels', []) + ['needs-triage'])))
    candidates = ([directory / (key(expected) + '.json'), directory / (key(triage_hint) + '.json')] if operation == 'create'
                  else directory.glob('*.json'))
    now = time.time()
    for path in candidates:
        try:
            document = json.loads(path.read_text(encoding='utf-8'))
            value, stamp = document['draft'], document['validated_at']
            valid = (document['schema_version'] == 1 and isinstance(value, dict)
                     and set(value) == {'repo', 'title', 'body_sha256', 'labels'}
                     and isinstance(value['repo'], str) and isinstance(value['title'], str)
                     and isinstance(value['body_sha256'], str)
                     and re.fullmatch(r'[0-9a-f]{64}', value['body_sha256'])
                     and isinstance(value['labels'], list)
                     and all(isinstance(label, str) for label in value['labels'])
                     and value['labels'] == sorted(set(value['labels']))
                     and path.name == key(value) + '.json'
                     and type(stamp) in (int, float) and math.isfinite(stamp)
                     and 0 <= now - stamp < max_age)
            if (valid and operation == 'create' and document.get('needs_triage_reason')
                    and value == triage_hint and value != expected):
                raise Refused('matching draft requires --label needs-triage on the create; add that label')
            if valid and all(value.get(name) == wanted for name, wanted in expected.items()):
                print('verify-issue-receipt: fresh matching receipt')
                return 0
        except (OSError, ValueError, KeyError, TypeError):
            continue
    command = [str(Path(script).resolve().with_name('check-issue-metadata.sh')),
               '--repo', repo, '--repo-root', '<target checkout>', '--owner-type', '<personal|organization>',
               '--title', title if title is not None else '<current-title>',
               '--body-file', values.get('--body-file', '<draft-file>')]
    proposed_labels = sorted(set(label.strip() for label in labels if label.strip()))
    for label in proposed_labels:
        command += ['--label', label]
    marker_advice = ('\nAn --agent-authored preflight omits --label needs-triage (it is derived; '
                     'pass --inapplicable <axis> instead), while a --human-authored preflight keeps it.'
                     if 'needs-triage' in proposed_labels else '')
    raise Refused('no fresh matching receipt; run the full preflight with the same draft bytes '
                  '(supply the target owner type, authorship, and required metadata):\n  '
                  + shlex.join(command) + ' --agent-authored (or --human-authored)' + marker_advice)


try:
    script, args = sys.argv[1], sys.argv[2:]
    if args == ['--help']:
        print('Usage: verify-issue-receipt.sh [--repo-root PATH] [--max-age-seconds N] -- gh issue create|edit ...\n'
              'Default freshness: 3600 seconds (strictly younger). Receipts are reusable.\n'
              'Exit 0 accepted; 1 refused (run preflight); 3 not covered; 2 usage/indeterminate.\n'
              'Argv only: shell text is never parsed or executed. Numeric edit selectors only.\n'
              'Use the exact --body-file bytes validated by check-issue-metadata.sh.')
        sys.exit(0)
    sys.exit(verify(args, script))
except Refused as error:
    print('verify-issue-receipt: ' + str(error), file=sys.stderr)
    sys.exit(1)
except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
    print('verify-issue-receipt: indeterminate: ' + str(error), file=sys.stderr)
    sys.exit(2)
PY
