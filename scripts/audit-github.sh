#!/usr/bin/env bash
# Read-only checklist audit. Stdout is NDJSON; diagnostics go to stderr.
# Requires python3 and gh. No secret value endpoint is ever requested.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -B - "$@" <<'PY'
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description='Read-only GitHub checklist audit (NDJSON). Exit 0: clean, 1: drift, 2: unavailable (takes precedence). Manual rows do not affect the exit code.')
parser.add_argument('--repo', help='[HOST/]OWNER/REPO; defaults to gh repository resolution')
parser.add_argument('--all', action='store_true', help='audit every catalog entry, including inactive template options')
parser.add_argument('--foreman', action='store_true', help='include Foreman labels in registry comparison')
parser.add_argument('--release-please', action='store_true', help='include release-please labels in registry comparison')
parser.add_argument('--bot-collaborator', help='expected bot login for the repository settings probe')
args = parser.parse_args()


def command(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Unavailable('command unavailable or timed out') from None
    if result.returncode:
        # Preserve status, never echo response bodies or credentials into reports.
        status = re.search(r'HTTP[ /]+(\d{3})', result.stderr)
        raise Unavailable('GitHub read unavailable' + (' (HTTP ' + status[1] + ')' if status else ' (no HTTP status)'))
    try:
        return json.loads(result.stdout) if result.stdout.strip() else None
    except ValueError:
        raise Unavailable('GitHub response is not valid JSON') from None


class Unavailable(Exception):
    pass


cache = {}
repo = None
owner = name = host = None
try:
    target = args.repo
    if not target:
        target = command(['gh', 'repo', 'view', '--json', 'nameWithOwner,url'])
        host = target['url'].split('/')[2]
        target = target['nameWithOwner']
    parts = target.split('/')
    if len(parts) == 3:
        host, owner, name = parts
    elif len(parts) == 2:
        owner, name = parts
    else:
        raise Unavailable('repository must be [HOST/]OWNER/REPO')
    if not all(part not in ('.', '..') and not part.startswith('-') and
               re.fullmatch(r'[A-Za-z0-9_.-]+', part) for part in parts):
        raise Unavailable('invalid repository')
    repo = owner + '/' + name
    target_error = None
except (Unavailable, KeyError, IndexError, TypeError) as error:
    target_error = str(error)
    owner = name = host = None


def api(endpoint, key=None, paginated=False, headers=()):
    """GET only, bounded pagination; cache evidence within this invocation."""
    identity = (endpoint, key, paginated, tuple(headers))
    if identity not in cache:
        try:
            if target_error:
                raise Unavailable(target_error)
            values = []
            for page in range(1, 11):
                path = endpoint
                if paginated:
                    path += ('&' if '?' in path else '?') + f'per_page=100&page={page}'
                argv = ['gh', 'api', '--method', 'GET', path]
                for header in headers:
                    argv += ['-H', header]
                if host:
                    argv += ['--hostname', host]
                try:
                    payload = command(argv)
                except Unavailable as error:
                    raise Unavailable(path + ': ' + str(error)) from None
                if not paginated:
                    cache[identity] = payload
                    break
                payload = payload.get(key) if key and isinstance(payload, dict) else payload
                if not isinstance(payload, list):
                    raise Unavailable('GitHub list response has an unsupported shape')
                values.extend(payload)
                if not payload:
                    cache[identity] = values
                    break
            else:
                raise Unavailable('GitHub pagination exceeded 10 pages; evidence incomplete')
        except Unavailable as error:
            cache[identity] = error
    result = cache[identity]
    if isinstance(result, Unavailable):
        raise result
    return result


def read(path, key=None, pages=False):
    return api('repos/' + repo + '/' + path, key, pages) if repo else api('', key, pages)


def field(data, name):
    if not isinstance(data, dict) or name not in data:
        raise Unavailable('GitHub response omitted ' + name)
    return data[name]


def names(path, key):
    values = read(path, key, True)
    if any(not isinstance(item, dict) or not isinstance(item.get('name'), str) for item in values):
        raise Unavailable('GitHub name inventory has an unsupported shape')
    return {item['name'] for item in values}


def secret(*expected):
    # This endpoint returns names/metadata only, never encrypted or clear values.
    missing = set(expected) - names('actions/secrets', 'secrets')
    return (not missing, 'secret names present' if not missing else 'missing secret names: ' + ', '.join(sorted(missing)))


def outcome(ok, reason):
    evidence = Evidence()
    if not ok:
        evidence.drift.append(reason)
    return evidence.resolve(reason)


def selector_labels(value):
    """Parse the same usable label shapes accepted by setup-github.sh."""
    try:
        selector = json.loads(value)
    except (ValueError, TypeError):
        return None
    labels = selector.get('labels') if isinstance(selector, dict) else selector
    labels = [labels] if isinstance(labels, str) else labels
    if isinstance(labels, list) and labels and all(isinstance(label, str) and label for label in labels):
        return labels
    return None


class Evidence:
    """Resolve a row once, with unavailable reads taking precedence over drift."""
    def __init__(self):
        self.failures = []
        self.drift = []

    def collect(self, label, read):
        try:
            return read()
        except Unavailable as error:
            self.failures.append(label + ': ' + str(error))
            return None

    def check(self, label, check):
        if self.collect(label, check) is False:
            self.drift.append(label)

    def resolve(self, reason):
        details = self.failures + (['drift: ' + ', '.join(self.drift)] if self.drift else [])
        return ('unknown' if self.failures else 'fail' if self.drift else 'pass',
                '; '.join(details) if details else reason)


def probe(entry):
    if target_error:
        raise Unavailable(target_error)
    item = entry['id']
    manual = 'manual evidence required: ' + (entry['probe'] or 'no read-only probe is available')
    if 'automated-settings-' in item:
        evidence = Evidence()
        settings = evidence.collect('repository settings', lambda: api('repos/' + repo))
        if args.bot_collaborator and not re.fullmatch(r'[A-Za-z0-9-]+', args.bot_collaborator):
            raise Unavailable('invalid bot collaborator login')
        if settings is not None:
            for key, expected in (('delete_branch_on_merge', True), ('allow_update_branch', True), ('allow_auto_merge', False)):
                evidence.check(key, lambda: field(settings, key) is expected)
        try:
            read('vulnerability-alerts')
        except Unavailable as error:
            if str(error).endswith('(HTTP 404)'):
                evidence.drift.append('vulnerability alerts disabled (HTTP 404)')
            else:
                evidence.failures.append('vulnerability alerts: ' + str(error))
        visibility = evidence.collect('visibility', lambda: field(settings, 'visibility')) if settings is not None else None
        if visibility == 'public':
            evidence.check('private vulnerability reporting', lambda: field(read('private-vulnerability-reporting'), 'enabled') is True)

        routing = {}
        inventory_complete = True
        if visibility in ('private', 'internal'):
            owner_type = evidence.collect('owner type', lambda: field(field(settings, 'owner'), 'type'))
            if owner_type == 'Organization':
                inherited = evidence.collect('organization variables', lambda: read('actions/organization-variables', 'variables', True))
                inventory_complete = inherited is not None
                if inherited is not None:
                    routing.update({row['name']: row['value'] for row in inherited})
            elif owner_type != 'User':
                inventory_complete = False
                evidence.failures.append('repository owner type unavailable')
        variables = evidence.collect('repository variables', lambda: read('actions/variables', 'variables', True))
        inventory_complete = inventory_complete and variables is not None
        if variables is not None:
            routing.update({row['name']: row['value'] for row in variables})
        expected = ('CI_RUNS_ON', 'BROWSER_RUNS_ON', 'IMAGE_BUILD_RUNS_ON', 'ISOLATED_RUNS_ON', 'MULTICORE_RUNS_ON')
        for key in expected:
            if key not in routing:
                # A failed inventory cannot establish that a variable is missing.
                if inventory_complete and (visibility == 'public' or key == 'CI_RUNS_ON'):
                    evidence.drift.append('missing runner selector: ' + key)
                continue
            labels = selector_labels(routing[key])
            valid = labels is not None
            if valid and visibility == 'public':
                selector = json.loads(routing[key])
                valid = labels == ['ubuntu-latest'] and not (isinstance(selector, dict) and 'group' in selector)
            if valid and key == 'ISOLATED_RUNS_ON':
                valid = all(label.lower() != 'self-hosted' for label in labels)
            if not valid:
                evidence.drift.append('invalid runner selector: ' + key)
        if visibility not in ('public', 'private', 'internal'):
            evidence.failures.append('repository visibility unavailable')
        if args.bot_collaborator:
            evidence.check('bot permission', lambda: field(read('collaborators/' + args.bot_collaborator + '/permission'), 'permission') in ('admin', 'maintain', 'write'))
        return evidence.resolve('repository merge/security settings and runner routing' + ('; bot permission checked' if args.bot_collaborator else '; no bot login specified'))
    if 'actions-secret-claude-code' in item:
        return outcome(*secret('CLAUDE_CODE_OAUTH_TOKEN'))
    if 'set-ci-app-client-id-' in item:
        evidence = Evidence()
        missing = []
        for expected, kind in (('CI_APP_PRIVATE_KEY', 'secrets'), ('CI_APP_CLIENT_ID', 'variables')):
            available = evidence.collect('repository ' + kind, lambda: names('actions/' + kind, kind))
            if available is not None and expected not in available:
                missing.append((expected, kind))
        if missing:
            owner_type = evidence.collect('repository owner type', lambda: field(field(api('repos/' + repo), 'owner'), 'type'))
            for expected, kind in missing:
                if owner_type == 'Organization':
                    available = evidence.collect('organization ' + kind, lambda: names('actions/organization-' + kind, kind))
                    if available is not None and expected not in available:
                        evidence.drift.append(expected + ' missing')
                elif owner_type == 'User':
                    evidence.drift.append(expected + ' missing')
            if owner_type not in ('Organization', 'User'):
                evidence.failures.append('repository owner type unavailable')
        return evidence.resolve('CI_APP_PRIVATE_KEY secret and CI_APP_CLIENT_ID variable present')
    if 'snyk' in item:
        ok, reason = secret('SNYK_TOKEN')
        # Schedule opt-in is explicit; name presence alone cannot prove posture.
        return ('manual', reason + '; workflow schedule and intended Snyk posture require operator verification')
    if 'install-and-activate-renovate-' in item:
        issues = read('issues?state=open', pages=True)
        found = any('pull_request' not in row and row.get('title') == 'Dependency Dashboard' and (row.get('user') or {}).get('login') in ('renovate[bot]', 'renovate-bot') for row in issues)
        return outcome(found, 'Renovate Dependency Dashboard ' + ('present' if found else 'absent'))
    if 'install-the-app-on-this-repo-' in item:
        # A succeeded workflow is evidence of token minting only when the workflow
        # itself contains the mint step. Whole-run success can skip that step.
        runs = read('actions/runs?status=success&per_page=100')['workflow_runs']
        for run in runs[:20]:
            jobs = read('actions/runs/' + str(run['id']) + '/jobs?filter=latest', 'jobs', True)
            for job in jobs:
                for step in (job.get('steps') or []):
                    if 'actions/create-github-app-token@' in step.get('name', '') and step.get('conclusion') == 'success':
                        return outcome(True, 'succeeded App token-minting step in run ' + str(run['id']))
        raise Unavailable('no succeeded token-minting step in the latest 20 successful runs; installation cannot be inferred')
    if any(part in item for part in ('coderabbit', 'greptile', 'gemini-code', 'connect-codex')):
        pulls = read('pulls?state=all&sort=updated&direction=desc&per_page=100')
        login = ('coderabbitai[bot]' if 'coderabbit' in item else
                 'chatgpt-codex-connector[bot]' if 'codex' in item else
                 'gemini-code-assist[bot]' if 'gemini' in item else 'greptile-apps[bot]')
        observed = False
        for pull in pulls[:20]:
            reviews = read('pulls/' + str(pull['number']) + '/reviews', pages=True)
            if any((review.get('user') or {}).get('login') == login for review in reviews):
                observed = True
                break
        return ('manual', login + (' review evidence present' if observed else ' not observed in latest 20 updated PRs') + '; connection and service preferences require manual verification')
    if 'import-the-branch-ruleset-' in item or 'add-closing-keywords-' in item or 'enable-unattributed-' in item:
        rules = read('rulesets?includes_parents=true', pages=True)
        if 'import-the-branch' in item:
            desired = json.loads(Path('.github/Branch Protection Ruleset - Protect Main.json').read_text())
            return outcome(any(row.get('name') == desired['name'] and row.get('enforcement') == 'active' for row in rules), 'named active ruleset presence only; content comparison: task audit:ruleset')
        return ('manual', 'read ' + str(len(rules)) + ' rulesets; approval/check conditions require task audit:ruleset and manual applicability review')
    if 'disable-github-codeql-' in item:
        return outcome(field(read('code-scanning/default-setup'), 'state') == 'not-configured', 'CodeQL default setup state')
    if 'free-sast-' in item or 'sast-coverage-' in item:
        read('code-scanning/default-setup')
        return ('manual', 'code scanning configuration readable; language coverage requires manual verification')
    if 'labels-run-task-' in item or 'after-a-copier-update-that-adds-labe-' in item:
        live = {row['name'].lower(): row for row in read('labels', pages=True)}
        # Use the same registry renderer as setup:github-labels, when available.
        renderer = Path('scripts/label-registry-render.mjs')
        if not renderer.exists():
            raise Unavailable('label registry renderer unavailable')
        argv = ['node', str(renderer), 'labels']
        if args.foreman or Path('.foreman.toml').exists():
            argv.append('--foreman')
        if args.release_please or Path('.release-please-manifest.json').exists():
            argv.append('--release-please')
        try:
            rendered = subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise Unavailable('label registry renderer unavailable') from None
        if rendered.returncode:
            raise Unavailable('label registry rendering failed')
        drift = []
        for line in rendered.stdout.splitlines():
            label, color, description = line.split('|', 2)
            row = live.get(label.lower())
            if row is None or field(row, 'color').lower() != color.lower() or (field(row, 'description') or '') != description:
                drift.append(label)
        if not rendered.stdout.strip():
            raise Unavailable('label registry renderer returned no labels')
        return outcome(not drift, 'registry label drift: ' + (', '.join(drift) or 'none') + '; extra labels preserved')
    if 'retire-any-legacy-agent-claim-' in item:
        labels = names('labels', None)
        retired_families = ('agent', 'claim:codex', 'claim:copilot')
        legacy = sorted(name for name in labels if any(
            name.lower() == family or name.lower().startswith(family + ':') for family in retired_families))
        return outcome(not legacy, 'legacy claim labels: ' + (', '.join(legacy) or 'none'))
    if 'org-issue-fields-run-' in item or 'org-issue-types-run-' in item or 'github-project-run-' in item:
        settings = api('repos/' + repo)
        owner_type = (settings.get('owner') or {}).get('type')
        if 'org-issue-' in item:
            if owner_type != 'Organization':
                raise Unavailable('organization repository required')
            # These two endpoints return the complete list and ignore page.
            if 'org-issue-types-run-' in item:
                types = api(f'orgs/{owner}/issue-types')
                enabled = {row['name'] for row in types if row.get('is_enabled') is True}
                return outcome({'Bug', 'Feature', 'Task', 'Research'} <= enabled, 'organization issue types')
            fields = api(f'orgs/{owner}/issue-fields', headers=['X-GitHub-Api-Version: 2026-03-10'])
            fields = fields['issue_fields'] if isinstance(fields, dict) else fields
            live = {row['name']: row for row in fields}
            # Keep equal to setup-github-issue-fields.sh / status.sh. Tier is a label.
            wanted = {
                'Product': ('text', ()),
                'Impact': ('single_select', ('minimal', 'low', 'medium', 'high', 'massive')),
                'Risk': ('single_select', ('trivial', 'low', 'medium', 'high', 'critical')),
                'Complexity': ('single_select', ('xs', 's', 'm', 'l', 'xl')),
                'Priority (AI)': ('single_select', ('p0', 'p1', 'p2', 'p3', 'p4')),
                'Effort': ('single_select', ('1', '2', '3', '5', '8', '13', '20')),
                **{name: ('single_select', ()) for name in ('Model family', 'Model', 'Model version', 'Model effort')},
            }
            ok = all(name in live and live[name].get('data_type') == dtype and
                     set(options) <= {option['name'] for option in (live[name].get('options') or [])}
                     for name, (dtype, options) in wanted.items())
            return outcome(ok, 'organization issue fields and options')
        # Inspect the owner board setup creates, rather than repository linkage.
        query = ('query($owner:String!){repositoryOwner(login:$owner){__typename '
                 '... on ProjectV2Owner{projectsV2(first:20){pageInfo{hasNextPage} nodes{id title closed '
                 'fields(first:100){pageInfo{hasNextPage} nodes{... on ProjectV2Field{name dataType} '
                 '... on ProjectV2SingleSelectField{name dataType options{name}}}}}}}}}')
        argv = ['gh', 'api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner]
        if host:
            argv += ['--hostname', host]
        payload = command(argv)
        if payload.get('errors'):
            raise Unavailable('GitHub GraphQL project read denied or incomplete (HTTP 200)')
        projects = payload['data']['repositoryOwner']['projectsV2']
        board = next((row for row in projects['nodes'] if row['title'] == f'{owner} Project' and row['closed'] is False), None)
        if board is None:
            if projects['pageInfo']['hasNextPage']:
                raise Unavailable('owner projects exceed 20 results; evidence incomplete')
            return outcome(False, 'owner Projects V2 board absent')
        fields = {row['name']: row for row in board['fields']['nodes'] if 'name' in row}
        status = fields.get('Status', {})
        ok = status.get('dataType') == 'SINGLE_SELECT' and {
            'Inbox', 'Icebox', 'Next', 'Todo', 'Shaping', 'Ready', 'Agent Queue',
            'In Progress', 'Verifying', 'In Review', 'Ready to Merge', 'Done', 'Deployed', 'Accepted'
        } <= {option['name'] for option in status.get('options', [])}
        if owner_type == 'User':
            ok = fields.get('Product', {}).get('dataType') == 'TEXT' and ok
        evidence = Evidence()
        if not ok and board['fields']['pageInfo']['hasNextPage']:
            evidence.failures.append('project fields exceed 100 results; evidence incomplete')
        elif not ok:
            evidence.drift.append('owner project field drift detected')
        if owner_type == 'Organization':
            inherited = evidence.collect('ORG_PROJECT_ID exposure', lambda: read('actions/organization-variables', 'variables', True))
            if inherited is not None:
                project_id = next((row['value'] for row in inherited if row['name'] == 'ORG_PROJECT_ID'), None)
                if project_id != board['id']:
                    evidence.drift.append('ORG_PROJECT_ID absent or differs from owner board id')
            variables = evidence.collect('repository project routing', lambda: read('actions/variables', 'variables', True))
            if variables is not None:
                overrides = {row['name']: row['value'] for row in variables}
                if 'ORG_PROJECT_ID' in overrides and overrides['ORG_PROJECT_ID'] != board['id']:
                    evidence.drift.append('repository ORG_PROJECT_ID differs from owner board id')
        elif owner_type != 'User':
            evidence.failures.append('repository owner type unavailable')
        return evidence.resolve('owner Projects V2 board, fields and routing')
    return ('manual', manual)


try:
    catalog = json.loads(Path('checklist-classes.json').read_text())
    entries = catalog['entries']
    if catalog.get('schema_version') != 1 or not isinstance(entries, list) or not entries:
        raise ValueError('unsupported or empty checklist catalog')
    if len({entry['id'] for entry in entries}) != len(entries):
        raise ValueError('duplicate catalog IDs')
    if not args.all:
        checklist = Path('docs/CHECKLIST.md').read_text()
        ids = set(re.findall(r'<!-- reconcile-id: ([a-z0-9-]+) -->', checklist))
        selected = {entry['id'] for entry in entries}
        if not ids or ids - selected:
            raise ValueError('checklist IDs missing from catalog')
        entries = [entry for entry in entries if entry['id'] in ids]
except (OSError, ValueError, KeyError, TypeError) as error:
    print('audit:github unavailable: ' + str(error), file=sys.stderr)
    sys.exit(2)

exit_code = 0
for entry in entries:
    try:
        result, reason = probe(entry)
    except (Unavailable, OSError, KeyError, TypeError, ValueError, AttributeError) as error:
        result, reason = 'unknown', str(error) or 'unsupported GitHub response'
    if result == 'unknown':
        exit_code = 2
    elif result == 'fail' and exit_code == 0:
        exit_code = 1
    print(json.dumps({'id': entry['id'], 'class': entry['class'], 'result': result,
                      'reason': reason, 'write_task': entry['write_task']}))
sys.exit(exit_code)
PY
