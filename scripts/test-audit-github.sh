#!/usr/bin/env bash
# Offline contract tests: stub gh, never contact GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -B - <<'PY'
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
catalog = json.loads((root / 'checklist-classes.json').read_text())
with tempfile.TemporaryDirectory(prefix='audit-github-') as tmp:
    fixture = Path(tmp)
    (fixture / 'scripts').mkdir()
    (fixture / 'docs').mkdir()
    (fixture / 'bin').mkdir()
    shutil.copy2(root / 'scripts/audit-github.sh', fixture / 'scripts/audit-github.sh')
    (fixture / 'scripts/label-registry-render.mjs').write_text("console.log('feature|abcdef|Feature work')\n")
    (fixture / 'checklist-classes.json').write_text(json.dumps(catalog))
    gh = fixture / 'bin/gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['AUDIT_TEST_LOG'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
if args[:2] == ['repo', 'view']:
    print(os.environ.get('AUDIT_TEST_REPO_VIEW', 'null'))
    sys.exit(0)
assert args[:3] == ['api', '--method', 'GET'] or args[:2] == ['api', 'graphql'], args
assert not any(word in args for word in ['--input', 'POST', 'PUT', 'PATCH', 'DELETE'])
endpoint = args[3] if args[1] == '--method' else 'graphql'
data = json.loads(Path(os.environ['AUDIT_TEST_DATA']).read_text())
key = endpoint.split('?')[0]
from urllib.parse import parse_qs
page = int(parse_qs(endpoint.partition('?')[2]).get('page', ['1'])[0])
value = data.get(endpoint, data.get(key, {'error': 403}) if page == 1 else
                 ({'variables': [], 'secrets': [], 'jobs': [], 'workflow_runs': [], 'issue_fields': []}
                  if isinstance(data.get(key), dict) and 'error' not in data[key] else []))
if key in ('orgs/acme/issue-types', 'orgs/acme/issue-fields'):
    value = data.get(key, {'error': 403})
if isinstance(value, dict) and 'error' in value:
    print('gh: permission unavailable (HTTP ' + str(value['error']) + ')', file=sys.stderr)
    sys.exit(1)
print(json.dumps(value) if value is not None else '')
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=str(fixture / 'bin') + os.pathsep + os.environ['PATH'],
               AUDIT_TEST_LOG=str(fixture / 'calls'), AUDIT_TEST_DATA=str(fixture / 'data.json'))
    def entry(fragment):
        return next(row for row in sorted(catalog['entries'], key=lambda row: row['source'] != 'root') if fragment in row['id'])
    settings = entry('automated-settings-')
    secrets = entry('actions-secret-')
    labels = entry('labels-run-')
    sast = entry('free-sast-')
    manual = entry('macos-add-')
    renovate = entry('install-and-activate-renovate-')
    app = entry('install-the-app-on-this-repo-')
    project = entry('github-project-run-')
    data = {
        'repos/acme/widget': {'delete_branch_on_merge': True, 'allow_update_branch': True, 'allow_auto_merge': False, 'visibility': 'public', 'owner': {'type': 'User'}},
        'repos/acme/widget/vulnerability-alerts': None,
        'repos/acme/widget/private-vulnerability-reporting': {'enabled': True},
        'repos/acme/widget/actions/variables': {'variables': [
            {'name': name, 'value': '"ubuntu-latest"'} for name in
            ['CI_RUNS_ON', 'BROWSER_RUNS_ON', 'IMAGE_BUILD_RUNS_ON', 'ISOLATED_RUNS_ON', 'MULTICORE_RUNS_ON']]},
        'repos/acme/widget/actions/secrets': {'secrets': [{'name': 'CLAUDE_CODE_OAUTH_TOKEN'}]},
        'repos/acme/widget/labels': [{'name': 'feature', 'color': 'abcdef', 'description': 'Feature work'}],
        'repos/acme/widget/issues': [{'title': 'Dependency Dashboard', 'user': {'login': 'renovate[bot]'}}],
        'repos/acme/widget/actions/runs': {'workflow_runs': [{'id': 42}]},
        'repos/acme/widget/actions/runs/42/jobs': {'jobs': [{'steps': [{'name': 'Run actions/create-github-app-token@sha', 'conclusion': 'success'}]}]},
        'graphql': {'data': {'repositoryOwner': {'projectsV2': {
            'nodes': [{'id': 'P1', 'title': 'acme Project', 'closed': False, 'fields': {
                'nodes': [{'name': 'Status', 'dataType': 'SINGLE_SELECT', 'options': [
                    {'name': name} for name in ['Inbox', 'Icebox', 'Next', 'Todo', 'Shaping', 'Ready', 'Agent Queue',
                                              'In Progress', 'Verifying', 'In Review', 'Ready to Merge', 'Done', 'Deployed', 'Accepted']]},
                    {'name': 'Product', 'dataType': 'TEXT'}], 'pageInfo': {'hasNextPage': False}}}],
            'pageInfo': {'hasNextPage': False}}}}},
    }
    def run(rows, expected, payload=None, extra=()):
        (fixture / 'docs/CHECKLIST.md').write_text('\n'.join('<!-- reconcile-id: ' + row['id'] + ' -->' for row in rows))
        (fixture / 'data.json').write_text(json.dumps(data if payload is None else payload))
        (fixture / 'calls').write_text('')
        result = subprocess.run(['bash', str(fixture / 'scripts/audit-github.sh'), '--repo', 'acme/widget', *extra], env=env, capture_output=True, text=True, check=False)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        output = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(output) == len(rows), (len(output), len(rows))
        assert {row['id'] for row in output} == {row['id'] for row in rows}
        assert all(set(row) == {'id', 'class', 'result', 'reason', 'write_task'} and row['reason'] for row in output)
        assert all(row['class'] == next(item['class'] for item in rows if item['id'] == row['id']) for row in output)
        return output
    output = run([settings, secrets, labels, renovate, app], 0)
    assert all(row['result'] == 'pass' for row in output)
    assert any('minting' in row['reason'] for row in output)
    assert run([project], 0)[0]['result'] == 'pass'
    # Invalid targets must block every probe, including GraphQL, before reads.
    for target in ('bad', '/owner/repo', '../repo', 'owner/..', '-host/owner/repo', 'owner//repo'):
        output = run(catalog['entries'], 2, extra=['--all', '--repo=' + target])
        assert all(row['result'] == 'unknown' for row in output)
        assert not (fixture / 'calls').read_text()
    # Empty default gh repo view responses must also yield one unknown per item.
    (fixture / 'docs/CHECKLIST.md').write_text('\n'.join('<!-- reconcile-id: ' + row['id'] + ' -->' for row in catalog['entries']))
    result = subprocess.run(['bash', str(fixture / 'scripts/audit-github.sh')], env=env, capture_output=True, text=True, check=False)
    assert result.returncode == 2 and not result.stderr, result
    assert all(json.loads(line)['result'] == 'unknown' for line in result.stdout.splitlines())

    def changed(endpoint, value):
        return dict(data, **{endpoint: value})

    fields_entry = entry('org-issue-fields-run-')
    types_entry = entry('org-issue-types-run-')
    assert all(row['result'] == 'unknown' for row in run([fields_entry, types_entry], 2))
    org = copy.deepcopy(data)
    org['repos/acme/widget']['owner']['type'] = 'Organization'
    inventory = 'repos/acme/widget/actions/organization-variables'
    org[inventory] = {'variables': [{'name': 'ORG_PROJECT_ID', 'value': 'P1'}]}
    assert run([project], 0, org)[0]['result'] == 'pass'
    assert 'orgs/acme/actions/variables/ORG_PROJECT_ID' not in (fixture / 'calls').read_text()
    for override in ('P1', 'wrong', ''):
        overridden = copy.deepcopy(org)
        overridden['repos/acme/widget/actions/variables']['variables'].append({'name': 'ORG_PROJECT_ID', 'value': override})
        row = run([project], 0 if override == 'P1' else 1, overridden)[0]
        assert row['result'] == ('pass' if override == 'P1' else 'fail')
    denied_override = dict(org, **{'repos/acme/widget/actions/variables': {'error': 403}})
    row = run([project], 2, denied_override)[0]
    assert row['result'] == 'unknown' and '403' in row['reason'] and 'actions/variables' in row['reason']
    org[inventory] = {'variables': [{'name': 'ORG_PROJECT_ID', 'value': 'wrong'}]}
    assert run([project], 1, org)[0]['result'] == 'fail'
    org[inventory] = {'variables': []}
    assert run([project], 1, org)[0]['result'] == 'fail'
    org[inventory] = {'error': 403}
    row = run([project], 2, org)[0]
    assert row['result'] == 'unknown' and '403' in row['reason'] and 'organization-variables' in row['reason']
    denied_drift = copy.deepcopy(org)
    denied_drift['graphql']['data']['repositoryOwner']['projectsV2']['nodes'][0]['fields']['nodes'][0]['options'] = []
    row = run([project], 2, denied_drift)[0]
    assert row['result'] == 'unknown' and all(text in row['reason'] for text in (
        'field drift', '403', 'organization-variables'))
    org[inventory] = {'variables': [{'name': 'ORG_PROJECT_ID', 'value': 'P1'}]}
    ci_app = entry('set-ci-app-client-id-')
    inherited_app = copy.deepcopy(org)
    inherited_app['repos/acme/widget/actions/organization-secrets'] = {'secrets': [{'name': 'CI_APP_PRIVATE_KEY'}]}
    inherited_app[inventory]['variables'].append({'name': 'CI_APP_CLIENT_ID', 'value': 'client-id'})
    assert run([ci_app], 0, inherited_app)[0]['result'] == 'pass'
    calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
    assert all('CI_APP_PRIVATE_KEY' not in ' '.join(call) for call in calls)
    assert all(not call[3].startswith('orgs/') for call in calls)
    for kind, name in (('secrets', 'CI_APP_PRIVATE_KEY'), ('variables', 'CI_APP_CLIENT_ID')):
        mixed = copy.deepcopy(inherited_app)
        credential = mixed['repos/acme/widget/actions/organization-' + kind][kind].pop()
        mixed['repos/acme/widget/actions/' + kind][kind].append(credential)
        # No inherited read is necessary for a credential present at repository scope.
        mixed['repos/acme/widget/actions/organization-' + kind] = {'error': 403}
        assert run([ci_app], 0, mixed)[0]['result'] == 'pass'
        missing = copy.deepcopy(inherited_app)
        missing['repos/acme/widget/actions/organization-' + kind][kind] = []
        row = run([ci_app], 1, missing)[0]
        assert row['result'] == 'fail' and name in row['reason']
        for scope in ('', 'organization-'):
            denied = dict(inherited_app, **{'repos/acme/widget/actions/' + scope + kind: {'error': 403}})
            row = run([ci_app], 2, denied)[0]
            assert row['result'] == 'unknown' and '403' in row['reason']
    repository_app = copy.deepcopy(data)
    repository_app['repos/acme/widget/actions/secrets']['secrets'].append({'name': 'CI_APP_PRIVATE_KEY'})
    repository_app['repos/acme/widget/actions/variables']['variables'].append({'name': 'CI_APP_CLIENT_ID', 'value': 'client-id'})
    assert run([ci_app], 0, repository_app)[0]['result'] == 'pass'
    row = run([ci_app], 1)[0]
    assert row['result'] == 'fail' and 'CI_APP_PRIVATE_KEY' in row['reason'] and 'CI_APP_CLIENT_ID' in row['reason']
    legacy = entry('retire-any-legacy-agent-claim-')
    assert run([legacy], 0)[0]['result'] == 'pass'
    for name in ('agent:codex', 'claim:codex', 'claim:codex:sol', 'Claim:Codex:Sol', 'claim:copilot', 'claim:copilot:model'):
        row = run([legacy], 1, changed('repos/acme/widget/labels', [{'name': name}]))[0]
        assert row['result'] == 'fail' and name in row['reason']
    missing_board = copy.deepcopy(data)
    missing_board['graphql']['data']['repositoryOwner']['projectsV2']['nodes'] = []
    assert run([project], 1, missing_board)[0]['result'] == 'fail'
    wrong_field = copy.deepcopy(data)
    wrong_field['graphql']['data']['repositoryOwner']['projectsV2']['nodes'][0]['fields']['nodes'][0]['options'] = []
    assert run([project], 1, wrong_field)[0]['result'] == 'fail'
    missing_option = copy.deepcopy(data)
    options = missing_option['graphql']['data']['repositoryOwner']['projectsV2']['nodes'][0]['fields']['nodes'][0]['options']
    options[:] = [option for option in options if option['name'] != 'Agent Queue']
    row = run([project], 1, missing_option)[0]
    assert row['result'] == 'fail' and 'field drift' in row['reason']
    assert run([project], 2, changed('graphql', {'errors': [{'message': 'denied'}]}))[0]['result'] == 'unknown'
    wanted = {
        'Product': ('text', []), 'Impact': ('single_select', ['minimal', 'low', 'medium', 'high', 'massive']),
        'Risk': ('single_select', ['trivial', 'low', 'medium', 'high', 'critical']),
        'Complexity': ('single_select', ['xs', 's', 'm', 'l', 'xl']),
        'Priority (AI)': ('single_select', ['p0', 'p1', 'p2', 'p3', 'p4']),
        'Effort': ('single_select', ['1', '2', '3', '5', '8', '13', '20']),
        **{name: ('single_select', []) for name in ('Model family', 'Model', 'Model version', 'Model effort')},
    }
    org['orgs/acme/issue-fields'] = {'issue_fields': [
        {'name': name, 'data_type': dtype, 'options': [{'name': option} for option in options]}
        for name, (dtype, options) in wanted.items()]}
    org['orgs/acme/issue-types'] = [{'name': name, 'is_enabled': True} for name in ('Bug', 'Feature', 'Task', 'Research')]
    assert all(row['result'] == 'pass' for row in run([fields_entry, types_entry], 0, org))
    calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
    assert any('X-GitHub-Api-Version: 2026-03-10' in call for call in calls)
    # Organization issue inventories return complete lists regardless of page.
    for endpoint, row in [('orgs/acme/issue-types', types_entry),
                          ('orgs/acme/issue-fields', fields_entry)]:
        assert run([row], 0, org)[0]['result'] == 'pass'
        calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
        requests = [call for call in calls if call[3].split('?')[0] == endpoint]
        assert len(requests) == 1 and requests[0][3] == endpoint, requests
        denied = dict(org, **{endpoint: {'error': 403}})
        result = run([row], 2, denied)[0]
        assert result['result'] == 'unknown' and '403' in result['reason'] and endpoint in result['reason']
        calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
        requests = [call for call in calls if call[3].split('?')[0] == endpoint]
        assert len(requests) == 1 and requests[0][3] == endpoint, requests
    list_fields = dict(org, **{'orgs/acme/issue-fields': org['orgs/acme/issue-fields']['issue_fields']})
    assert run([fields_entry], 0, list_fields)[0]['result'] == 'pass'
    for field_change in ('missing', 'type', 'options'):
        drifted = copy.deepcopy(org)
        fields = drifted['orgs/acme/issue-fields']['issue_fields']
        if field_change == 'missing':
            fields.pop(1)
        elif field_change == 'type':
            fields[1]['data_type'] = 'text'
        else:
            fields[1]['options'].pop()
        assert run([fields_entry], 1, drifted)[0]['result'] == 'fail'
    org['orgs/acme/issue-types'][0]['is_enabled'] = False
    assert run([types_entry], 1, org)[0]['result'] == 'fail'
    org['orgs/acme/issue-types'] = []
    assert run([types_entry], 1, org)[0]['result'] == 'fail'
    for endpoint, row in [('orgs/acme/issue-fields', fields_entry), ('orgs/acme/issue-types', types_entry)]:
        denied = dict(org, **{endpoint: {'error': 403}})
        assert run([row], 2, denied)[0]['result'] == 'unknown'

    # Public runners must all be explicit ubuntu-latest; private defaults may be omitted.
    for value in ([], [{'name': 'CI_RUNS_ON', 'value': '"self-hosted"'}]):
        assert run([settings], 1, changed('repos/acme/widget/actions/variables', {'variables': value}))[0]['result'] == 'fail'
    public_self_hosted = copy.deepcopy(data)
    public_self_hosted['repos/acme/widget/actions/variables']['variables'][0]['value'] = '"self-hosted"'
    assert run([settings], 1, public_self_hosted)[0]['result'] == 'fail'
    for visibility in ('private', 'internal'):
        private = copy.deepcopy(data)
        private['repos/acme/widget']['visibility'] = visibility
        private['repos/acme/widget/actions/variables']['variables'] = [{'name': 'CI_RUNS_ON', 'value': '"self-hosted"'}]
        assert run([settings], 0, private)[0]['result'] == 'pass'
        private['repos/acme/widget/actions/variables']['variables'] = []
        assert run([settings], 1, private)[0]['result'] == 'fail'
        private['repos/acme/widget']['owner']['type'] = 'Organization'
        private['repos/acme/widget/actions/organization-variables'] = {'variables': [{'name': 'CI_RUNS_ON', 'value': '"ubuntu-latest"'}]}
        assert run([settings], 0, private)[0]['result'] == 'pass'
        private['repos/acme/widget/actions/variables']['variables'] = [{'name': 'CI_RUNS_ON', 'value': '"self-hosted"'}]
        private['repos/acme/widget/actions/organization-variables'] = {'variables': [{'name': 'BROWSER_RUNS_ON', 'value': 'invalid'}]}
        assert run([settings], 1, private)[0]['result'] == 'fail'
        private['repos/acme/widget/actions/variables']['variables'].append({'name': 'BROWSER_RUNS_ON', 'value': '"ubuntu-latest"'})
        assert run([settings], 0, private)[0]['result'] == 'pass'
        private['repos/acme/widget/actions/variables']['variables'].append({'name': 'ISOLATED_RUNS_ON', 'value': '"self-hosted"'})
        assert run([settings], 1, private)[0]['result'] == 'fail'
    private_org = copy.deepcopy(data)
    private_org['repos/acme/widget'].update(visibility='private', owner={'type': 'Organization'})
    private_org['repos/acme/widget/actions/organization-variables'] = {'error': 403}
    row = run([settings], 2, private_org)[0]
    assert row['result'] == 'unknown' and '403' in row['reason'] and 'organization-variables' in row['reason']
    private_org['repos/acme/widget']['owner']['type'] = 'User'
    assert run([settings], 0, private_org)[0]['result'] == 'pass'
    assert 'organization-variables' not in (fixture / 'calls').read_text()
    for selector in (['ubuntu-latest'], {'labels': ['ubuntu-latest']}, {'labels': 'ubuntu-latest'}):
        selectors = copy.deepcopy(data)
        for variable in selectors['repos/acme/widget/actions/variables']['variables']:
            variable['value'] = json.dumps(selector)
        assert run([settings], 0, selectors)[0]['result'] == 'pass'
    for index, variable in enumerate(data['repos/acme/widget/actions/variables']['variables']):
        grouped = copy.deepcopy(data)
        grouped['repos/acme/widget/actions/variables']['variables'][index]['value'] = json.dumps({
            'group': 'persistent', 'labels': 'ubuntu-latest'})
        row = run([settings], 1, grouped)[0]
        assert row['result'] == 'fail' and variable['name'] in row['reason']
    grouped_private = copy.deepcopy(data)
    grouped_private['repos/acme/widget']['visibility'] = 'private'
    grouped_private['repos/acme/widget/actions/variables']['variables'][0]['value'] = json.dumps({
        'group': 'persistent', 'labels': 'ubuntu-latest'})
    assert run([settings], 0, grouped_private)[0]['result'] == 'pass'
    pages = copy.deepcopy(private_org)
    pages['repos/acme/widget/actions/variables'] = {'variables': [
        {'name': 'CI_RUNS_ON', 'value': '"ubuntu-latest"'}] + [
        {'name': 'UNRELATED_' + str(i), 'value': 'unused'} for i in range(29)]}
    pages['repos/acme/widget/actions/variables?per_page=100&page=2'] = {'variables': [
        {'name': 'ISOLATED_RUNS_ON', 'value': '["SELF-HOSTED", "linux"]'}]}
    assert run([settings], 1, pages)[0]['result'] == 'fail'
    busy = changed('repos/acme/widget/actions/runs', {'total_count': 1100, 'workflow_runs': [{'id': 42}] * 100})
    assert run([app], 0, busy)[0]['result'] == 'pass'
    calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
    assert len([call for call in calls if call[3].split('?')[0] == 'repos/acme/widget/actions/runs']) == 1
    drifted = copy.deepcopy(data)
    drifted['repos/acme/widget']['delete_branch_on_merge'] = False
    drifted['repos/acme/widget/vulnerability-alerts'] = {'error': 404}
    row = run([settings], 1, drifted)[0]
    assert row['result'] == 'fail' and '404' in row['reason'] and 'delete_branch_on_merge' in row['reason']
    drifted['repos/acme/widget/actions/variables'] = {'error': 403}
    row = run([settings], 2, drifted)[0]
    assert all(text in row['reason'] for text in ('404', '403', 'vulnerability alerts disabled', 'actions/variables', 'delete_branch_on_merge'))
    assert run([settings], 2, changed('repos/acme/widget/actions/variables', {'error': 403}))[0]['result'] == 'unknown'
    assert run([renovate], 1, changed('repos/acme/widget/issues', [
        {'title': 'Dependency Dashboard', 'user': None},
        {'title': 'Dependency Dashboard', 'user': {'login': 'renovate[bot]'}, 'pull_request': {}}]))[0]['result'] == 'fail'
    assert 'token-minting' in run([app], 2, changed('repos/acme/widget/actions/runs/42/jobs', {'jobs': [{'steps': None}]}))[0]['reason']
    connector = entry('connect-codex')
    null_review = dict(data, **{'repos/acme/widget/pulls': [{'number': 1}], 'repos/acme/widget/pulls/1/reviews': [{'user': None}]})
    row = run([connector], 0, null_review)[0]
    assert row['result'] == 'manual' and 'not observed' in row['reason']
    observed_review = copy.deepcopy(null_review)
    observed_review['repos/acme/widget/pulls/1/reviews'] = [{'user': {'login': 'chatgpt-codex-connector[bot]'}}]
    row = run([connector], 0, observed_review)[0]
    assert row['result'] == 'manual' and 'review evidence present' in row['reason']
    for endpoint in ('repos/acme/widget/pulls', 'repos/acme/widget/pulls/1/reviews'):
        denied_review = dict(null_review, **{endpoint: {'error': 403}})
        assert run([connector], 2, denied_review)[0]['result'] == 'unknown'
    snyk = entry('choose-the-snyk-posture-')
    for tokens in ([], [{'name': 'SNYK_TOKEN'}]):
        row = run([snyk], 0, changed('repos/acme/widget/actions/secrets', {'secrets': tokens}))[0]
        assert row['result'] == 'manual' and 'require operator verification' in row['reason']
    assert run([snyk], 2, changed('repos/acme/widget/actions/secrets', {'error': 403}))[0]['result'] == 'unknown'
    rules = [entry('add-closing-keywords-'), entry('enable-unattributed-')]
    output = run(rules, 0, changed('repos/acme/widget/rulesets', []))
    assert all(row['result'] == 'manual' and 'manual applicability review' in row['reason'] for row in output)
    assert all(row['result'] == 'unknown' for row in run(rules, 2))
    row = run([sast], 0, changed('repos/acme/widget/code-scanning/default-setup', {'state': 'configured'}))[0]
    assert row['result'] == 'manual' and 'language coverage requires manual verification' in row['reason']
    assert run([labels], 0, changed('repos/acme/widget/labels', [{'name': 'FEATURE', 'color': 'abcdef', 'description': 'Feature work'}]))[0]['result'] == 'pass'
    # Rendered profiles include only their active template IDs, never root IDs
    # or catalog items from options Copier omitted.
    rendered = [next(row for row in catalog['entries'] if row['source'] == 'template' and fragment in row['id'])
                for fragment in ('automated-settings-', 'actions-secret-')]
    assert all(row['id'].startswith('template-') for row in run(rendered, 0))
    drift = dict(data, **{'repos/acme/widget/actions/secrets': {'secrets': []}})
    assert run([secrets], 1, drift)[0]['result'] == 'fail'
    for status in (401, 403, 404, 429, 500):
        denied = dict(data, **{'repos/acme/widget/actions/secrets': {'error': status}})
        row = run([secrets], 2, denied)[0]
        assert row['result'] == 'unknown' and str(status) in row['reason']
    assert any(row['result'] == 'fail' for row in run([secrets, manual], 1, drift))
    assert run([manual], 0)[0]['result'] == 'manual'
    assert run([sast], 2)[0]['class'] == 'unknown-when-unprivileged'
    # All four classifications have the same read-only probe semantics.
    fleet = dict(settings, **{'class': 'agent-apply-with-fleet-approval'})
    custom = dict(catalog, entries=[fleet])
    (fixture / 'checklist-classes.json').write_text(json.dumps(custom))
    assert run([fleet], 0)[0]['class'] == 'agent-apply-with-fleet-approval'
    (fixture / 'checklist-classes.json').write_text(json.dumps(catalog))
    # Every catalog ID, including inactive options, produces exactly one row.
    output = run(catalog['entries'], 2, extra=['--all'])
    assert len(output) == len(catalog['entries'])
    calls = [json.loads(line) for line in (fixture / 'calls').read_text().splitlines()]
    secret_calls = [call for call in calls if 'actions/secrets' in ' '.join(call)]
    assert len(secret_calls) == 2, secret_calls  # cached metadata inventory
    assert secret_calls[0][3].split('?')[0] == 'repos/acme/widget/actions/secrets'
    assert 'CLAUDE_CODE_OAUTH_TOKEN' not in ' '.join(secret_calls[0])
    # Only vulnerability-alerts treats 404 as disabled; denied reads stay unknown.
    disabled = changed('repos/acme/widget/vulnerability-alerts', {'error': 404})
    row = run([settings], 1, disabled)[0]
    assert row['result'] == 'fail' and 'vulnerability alerts disabled' in row['reason']
    denied = changed('repos/acme/widget/vulnerability-alerts', {'error': 403})
    row = run([settings], 2, denied)[0]
    assert row['result'] == 'unknown' and '403' in row['reason']
    invalid = dict(data, **{'repos/acme/widget/actions/secrets': {'unexpected': []}})
    assert run([secrets], 2, invalid)[0]['result'] == 'unknown'
    # A skipped mint step is not installation evidence.
    skipped = dict(data, **{'repos/acme/widget/actions/runs/42/jobs': {'jobs': [{'steps': [{'name': 'Run actions/create-github-app-token@sha', 'conclusion': 'skipped'}]}]}})
    assert run([app], 2, skipped)[0]['result'] == 'unknown'
    # Exhaustion and a denied later page cannot make a partial list pass/fail.
    many = dict(data, **{'repos/acme/widget/labels': [{'name': 'x' + str(i), 'color': 'ffffff', 'description': ''} for i in range(100)]})
    many.update({'repos/acme/widget/labels?per_page=100&page=' + str(page): many['repos/acme/widget/labels']
                 for page in range(1, 11)})
    assert '10 pages' in run([labels], 2, many)[0]['reason']
    later = dict(many, **{'repos/acme/widget/labels?per_page=100&page=2': {'error': 403}})
    assert '403' in run([labels], 2, later)[0]['reason']
    # Unknown checklist IDs are rejected before any GitHub read.
    (fixture / 'docs/CHECKLIST.md').write_text('<!-- reconcile-id: unregistered -->')
    result = subprocess.run(['bash', str(fixture / 'scripts/audit-github.sh'), '--repo', 'acme/widget'], env=env, capture_output=True, text=True, check=False)
    assert result.returncode == 2 and not result.stdout
print('audit:github: complete catalog, four classes, drift, permissions, pagination, read-only calls and name-only secrets passed')
PY
