#!/usr/bin/env bash
# Offline behavior tests; the Python stub never calls GitHub.
set -euo pipefail
asset_dir="$(cd "$(dirname "$0")" && pwd)"
python3 -B - "$asset_dir" "$@" <<'PY'
import copy
import re
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ASSETS = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('fleet_report', ASSETS / 'fleet-report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

STUB = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FLEET_REPORT_FIXTURE'])
state = json.loads((root/'state.json').read_text())
a = sys.argv[1:]
repo = a[a.index('--repo')+1]
operation = a[1]
if operation == 'list':
    value = [v for k,v in state.items() if k.startswith(repo+'#') and v['title'].startswith('(HUMAN):')]
elif operation == 'view':
    if (root/'old-gh').exists():
        print('Unknown JSON field: "parent"', file=sys.stderr)
        sys.exit(1)
    key = repo+'#'+a[2]
    value = state[key]
    if (root/'fail-read').exists():
        sys.exit(1)
elif operation in ('edit','reopen'):
    key = repo+'#'+a[2]
    with (root/'writes').open('a') as f:
        f.write(operation+' '+key+'\\n')
    if (root/'fail-write').exists():
        sys.exit(1)
    if (root/'fail-target').exists() and key in (root/'fail-target').read_text().splitlines():
        print('Injected issue write failure', file=sys.stderr)
        sys.exit(1)
    if operation == 'edit':
        assert a[-2:] == ['--body-file', '-']
        body = sys.stdin.read()
        if len(body) > 65536:
            print('Issue body is too long', file=sys.stderr)
            sys.exit(1)
        state[key]['body'] = body
        if 'Human follow-up (' in body:
            routing = 'pending' if 'Human follow-up (publication pending in ' in body else 'routed'
            with (root/'routing-writes').open('a') as f:
                f.write(key + ' ' + routing + '\\n')
    else:
        state[key]['state'] = 'OPEN'
        state[key]['stateReason'] = ''
        if (root/'grow-on-reopen').exists():
            body = state[key]['body']
            state[key]['body'] = 'P' * (65536 - len(body) - 2) + '\\n\\n' + body
    (root/'state.json').write_text(json.dumps(state))
    sys.exit(0)
else:
    sys.exit(2)
print(json.dumps(value))
'''


class FleetReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.gh = self.root/'gh'
        self.gh.write_text(STUB)
        self.gh.chmod(0o755)
        self.env = dict(os.environ, FLEET_REPORT_FIXTURE=str(self.root), PYTHONDONTWRITEBYTECODE='1')
        self.data = {'version': 1, 'run': {'release': 'v9.0.0', 'epic': {'repo': 'demo/fleet', 'number': 1}},
                     'repositories': [{'repository': 'sample/app',
                                       'tracking_issue': {'repo': 'sample/app', 'number': 2},
                                       'pr': 3, 'head': 'a'*40, 'state': 'working',
                                       'answers_changed': [{'key': 'devcontainer', 'before': False, 'after': True}],
                                       'non_adoption': ['keep local task'],
                                       'skills_pin': {'repository': 'sample/app', 'pin': 'v1.0.0',
                                                      'minimum': 'v1.0.0', 'latest': 'v2.0.0',
                                                      'verdict': 'ok', 'pin_lag': 'behind v2.0.0',
                                                      'planned_action': {'pin': 'leave'}}}]}
        self.state = {}
        for rendered in report.render(report.validate(self.data)):
            repo, n = report.reference(rendered['issue'])
            begin, end = report.markers(self.data['run'], rendered['kind'])
            self.state[f'{repo}#{n}'] = {'number': n, 'title': 'Fleet' if n == 1 else 'Update',
                                       'body': f'Human prose\n\n{begin}\nold\n{end}\n\nKeep this tail.\n',
                                       'state': 'OPEN', 'stateReason': '', 'labels': [{'name': 'epic'}] if n == 1 else [],
                                       'parent': None, 'milestone': None}
        self.save()

    def save(self):
        (self.root/'state.json').write_text(json.dumps(self.state))

    def load(self):
        self.state = json.loads((self.root/'state.json').read_text())
        return self.state

    def invoke(self, command='write', success=True):
        path = self.root/'input.json'
        path.write_text(json.dumps(self.data))
        result = subprocess.run([sys.executable, str(ASSETS/'fleet-report.py'), command,
                                 '--input', str(path), '--gh', str(self.gh)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr + result.stdout)
        return result

    def writes(self):
        path = self.root/'writes'
        return path.read_text().splitlines() if path.exists() else []

    def write_receipt_verified_bodies(self, epic, tracking):
        self.data['run']['epic'] = {'repo': 'testowner/testrepo', 'number': 10}
        self.state['testowner/testrepo#10'] = {
            **self.state.pop('demo/fleet#1'), 'number': 10, 'body': epic.read_text()
        }
        self.state['sample/app#2']['body'] = tracking.read_text()
        self.save()
        self.invoke()
        self.assertCountEqual(self.writes(), ['edit testowner/testrepo#10', 'edit sample/app#2'])

    def add_humans(self):
        self.data['repositories'][0]['reconcile'] = [
            {'item': 'app-install', 'probe': 'token mint failed', 'action': 'pending',
             'class': 'human-only', 'task': 'Install the CI App'}]
        self.state['demo/fleet#8'] = {
            'number': 8, 'title': '(HUMAN): Complete manual setup for release', 'state': 'OPEN',
            'stateReason': '', 'closedAt': None, 'labels': [{'name': 'human'}, {'name': 'umbrella'}],
            'milestone': None, 'parent': {'url': 'https://github.com/demo/fleet/issues/1'},
            'body': '## Problem\n\nManual setup.\n\n## Acceptance criteria\n\n'
                    '- [x] [HUMAN] Previous task\n\n## Provenance\n\nCollector scope: demo/fleet#1\n'}
        self.save()

    def test_render_is_read_only_deterministic_and_optional_rows_are_not_run(self):
        first = self.invoke('render').stdout
        self.assertEqual(first, self.invoke('render').stdout)
        self.assertEqual(self.writes(), [])
        body = json.loads(first)['reports'][1]['body']
        self.assertIn('### Reconcile\n\nnot run', body)
        self.assertIn('### Devcontainer and image\n\nnot run', body)
        self.assertIn('bump', report.text('bump'))
        self.assertIn('pin: v1.0.0', body)
        self.assertIn('keep local task', body)

    def test_rebuild_queue_is_wave_ordered_and_unique(self):
        self.data['rebuild_queue'] = [
            {'wave': 2, 'workspace': 'coder-b', 'command': 'coder update b'},
            {'wave': 1, 'workspace': 'cli-a', 'command': 'devcontainer up --workspace-folder /a'},
        ]
        body = json.loads(self.invoke('render').stdout)['reports'][0]['body']
        self.assertLess(body.index('cli-a'), body.index('coder-b'))
        self.assertIn('after each wave merges', body)
        self.data['rebuild_queue'].append(dict(self.data['rebuild_queue'][0]))
        self.invoke('render', success=False)

    def test_rebuild_commands_render_as_code_spans(self):
        for command, expected in [
            ('echo  two  spaces', '`echo  two  spaces`'),
            ('echo $HOME ~/work', '`echo $HOME ~/work`'),
            ('echo `date`', '`` echo `date` ``'),
            ('echo a | cat', r'`echo a \| cat`'),
            (' echo ', '`  echo  `'),
        ]:
            with self.subTest(command=command):
                self.data['rebuild_queue'] = [{'wave': 1, 'workspace': 'cli-a', 'command': command}]
                body = json.loads(self.invoke('render').stdout)['reports'][0]['body']
                self.assertIn('| 1 | cli-a | ' + expected + ' |', body)

    def test_rebuild_command_refuses_control_characters(self):
        for char in (chr(i) for i in list(range(0x20)) + [0x7f]):
            with self.subTest(char=ord(char)):
                self.data['rebuild_queue'] = [
                    {'wave': 1, 'workspace': 'cli-a', 'command': 'cd /app' + char + 'devcontainer up'},
                ]
                result = self.invoke('render', success=False)
                self.assertIn('rebuild command for workspace \'cli-a\' must not contain control characters',
                              result.stderr)
                self.assertEqual(self.writes(), [])

    def test_non_adoption_apostrophe_renders_literally(self):
        value = "Keep the repository's custom deployment task"
        self.data['repositories'][0]['non_adoption'] = [value]
        body = json.loads(self.invoke('render').stdout)['reports'][1]['body']
        self.assertIn("- " + value, body)
        self.assertNotIn('&#x27;', body)
        self.assertNotIn('&\\#x27;', body)

    def test_task_key_matches_literal_and_existing_escaped_apostrophes(self):
        expected = report.task_key("Keep the repository's task (from sample/app#2)", 'demo/fleet')
        for task in ("Keep the repository's task", "Keep the repository&#x27;s task",
                     "Keep the repository&\\#x27;s task"):
            with self.subTest(task=task):
                self.assertEqual(report.task_key(task + ' (from sample/app#2)', 'demo/fleet'),
                                 expected)
        self.assertEqual(report.task_key(report.text("Keep the repository's task")
                                         + ' (from sample/app#2)', 'demo/fleet'), expected)

    def test_old_gh_names_minimum_version_before_any_write(self):
        (self.root/'old-gh').touch()
        result = self.invoke(success=False)
        self.assertIn('GitHub CLI 2.94.0 or newer', result.stderr)
        self.assertEqual(self.writes(), [])

    def test_unchanged_is_no_edit_and_changed_row_edits_once(self):
        self.invoke()
        self.assertEqual(len(self.writes()), 2)
        saved = copy.deepcopy(self.load())
        self.invoke()
        self.assertEqual(saved, self.load())
        self.assertEqual(len(self.writes()), 2)
        self.data['repositories'][0]['answers_changed'][0]['after'] = 'new'
        self.invoke()
        self.assertEqual(self.writes()[2:], ['edit sample/app#2'])
        for issue in self.load().values():
            self.assertTrue(issue['body'].startswith('Human prose\n\n'))
            self.assertTrue(issue['body'].endswith('\n\nKeep this tail.\n'))

    def test_missing_duplicate_or_reversed_marker_refuses_all_writes(self):
        for kind in ('missing', 'duplicate', 'reversed', 'inline'):
            with self.subTest(kind=kind):
                initial = self.state['sample/app#2']['body']
                begin, end = report.markers(self.data['run'], 'repository')
                if kind == 'missing':
                    self.state['sample/app#2']['body'] = initial.replace(begin, '')
                elif kind == 'duplicate':
                    self.state['sample/app#2']['body'] = initial + '\n' + begin
                elif kind == 'inline':
                    self.state['sample/app#2']['body'] = initial.replace(begin, 'inline ' + begin)
                else:
                    self.state['sample/app#2']['body'] = end + '\n' + begin
                self.save()
                self.invoke(success=False)
                self.assertEqual(self.writes(), [])
                self.state['sample/app#2']['body'] = initial

    def test_humans_grouped_once_never_ticked_and_linked_from_source(self):
        self.add_humans()
        self.invoke()
        current = self.load()
        body = current['demo/fleet#8']['body']
        self.assertIn('### sample\n\n- [ ] [HUMAN] Fleet follow-ups — 1 follow-up', body)
        self.assertIn('- [x] [HUMAN] Previous task', body)
        self.assertIn('from sample/app#2', body)
        self.assertNotIn('token mint failed', body)
        source = current['sample/app#2']['body']
        self.assertIn('Human follow-up (tracked in [demo/fleet#8]', source)
        self.assertIn('Install the CI App', source)
        self.assertIn('token mint failed', source)
        count = len(self.writes())
        self.invoke()
        self.assertEqual(len(self.writes()), count)
        # A human's tick remains checked and newer probe evidence must not duplicate the task.
        self.state['demo/fleet#8']['body'] = body.replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
        self.save()
        self.data['repositories'][0]['reconcile'][0]['probe'] = 'still missing'
        self.invoke()
        body = self.load()['demo/fleet#8']['body']
        self.assertEqual(body.count('Fleet follow-ups'), 1)
        self.assertIn('- [x] [HUMAN] Fleet', body)

    def test_new_task_reopens_completed_collector_with_an_unticked_line(self):
        self.add_humans()
        self.invoke()
        collector = self.load()['demo/fleet#8']
        collector.update(state='CLOSED', stateReason='COMPLETED')
        self.data['repositories'][0]['reconcile'].append({
            'item': 'second-gap', 'probe': 'manual: configure it', 'action': 'none',
            'class': 'human-only', 'task': 'Configure the second gap',
        })
        self.save()
        self.invoke()
        current = self.load()
        self.assertEqual(current['demo/fleet#8']['state'], 'OPEN')
        self.assertEqual(current['demo/fleet#8']['body'].count('Fleet follow-ups'), 1)
        self.assertIn('- [ ] [HUMAN] Fleet follow-ups — 2 follow-ups', current['demo/fleet#8']['body'])
        self.assertIn('Configure the second gap', current['sample/app#2']['body'])
        self.assertIn('reopen demo/fleet#8', self.writes())
        count = len(self.writes())
        self.invoke()
        self.assertEqual(len(self.writes()), count)

    def test_shrink_repends_the_checked_line(self):
        self.add_humans()
        rows = self.data['repositories'][0]['reconcile']
        rows.append(dict(rows[0], item='second', task='Configure another setting'))
        self.invoke()
        collector = self.load()['demo/fleet#8']
        collector['body'] = collector['body'].replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
        collector.update(state='CLOSED', stateReason='COMPLETED')
        self.save()

        for row, count in zip(rows, (1, 0)):
            with self.subTest(count=count):
                row['probe'] = 'pass: configuration'
                self.invoke()
                collector = self.load()['demo/fleet#8']
                self.assertEqual(collector['state'], 'OPEN')
                self.assertIn(f'- [ ] [HUMAN] Fleet follow-ups — {count} follow-up', collector['body'])
                self.assertEqual(collector['body'].count('Fleet follow-ups'), 1)
        self.assertIn('reopen demo/fleet#8', self.writes())

    def test_tracker_failure_cannot_create_a_tick_for_unseen_work(self):
        self.add_humans()
        self.invoke()
        current = self.load()
        old_line = current['demo/fleet#8']['body']
        old_tracker = current['sample/app#2']['body']
        rows = self.data['repositories'][0]['reconcile']
        rows.append(dict(rows[0], item='second', task='Set up another feature'))
        (self.root/'fail-target').write_text('sample/app#2')
        self.assertIn('could not publish sample/app#2', self.invoke(success=False).stderr)
        current = self.load()
        self.assertEqual(current['demo/fleet#8']['body'], old_line)
        self.assertEqual(current['sample/app#2']['body'], old_tracker)

        current['demo/fleet#8']['body'] = old_line.replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
        self.save()
        (self.root/'fail-target').unlink()
        first_retry_write = len(self.writes())
        self.invoke()
        current = self.load()
        self.assertIn('- [ ] [HUMAN] Fleet follow-ups — 2 follow-ups', current['demo/fleet#8']['body'])
        self.assertIn('Set up another feature', current['sample/app#2']['body'])
        self.assertIn('Human follow-up (tracked in', current['sample/app#2']['body'])
        self.assertEqual(self.writes()[first_retry_write:],
                         ['edit sample/app#2', 'edit demo/fleet#8', 'edit sample/app#2'])
        routing = (self.root/'routing-writes').read_text().splitlines()
        self.assertEqual(routing[-2:], ['sample/app#2 pending', 'sample/app#2 routed'])

    def test_changed_input_after_ticks_publishes_every_repository(self):
        self.add_humans()
        self.add_tracking_issue('sample/later')
        self.save()
        self.invoke()
        collector = self.load()['demo/fleet#8']
        collector['body'] = collector['body'].replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
        self.save()
        first_write = len(self.writes())
        for row in self.data['repositories']:
            row['reconcile'][0]['task'] = f"New setup in {row['repository']}"
        self.invoke()
        current = self.load()
        self.assertEqual(current['demo/fleet#8']['body'].count('- [ ] [HUMAN] Fleet follow-ups — 1 follow-up'), 2)
        self.assertEqual(self.writes()[first_write:],
                         ['edit sample/app#2', 'edit sample/later#2', 'edit demo/fleet#8',
                          'edit sample/app#2', 'edit sample/later#2'])
        for repo in ('sample/app', 'sample/later'):
            self.assertIn(f'New setup in {repo}', current[f'{repo}#2']['body'])
            self.assertIn('Human follow-up (tracked in', current[f'{repo}#2']['body'])

    def test_many_changing_snapshots_keep_one_constant_size_line(self):
        self.add_humans()
        self.add_tracking_issue('sample/later')
        row = self.data['repositories'][0]['reconcile'][0]
        collector = {'repo': 'demo/fleet', 'number': 8}
        body = self.state['demo/fleet#8']['body']
        sizes = set()
        bodies = {('demo/fleet', 1): self.state['demo/fleet#1']['body'],
                  **{('sample/' + name, 2): self.state[f'sample/{name}#2']['body']
                     for name in ('app', 'later')}}
        for index in range(350):
            row['task'] = f'Configure setting {index}'
            _, routed, edits, skipped = report.publication_plan(self.data, collector, body, bodies)
            body, overflow = report.collector_proposal(body, collector, edits, routed.keys() - skipped.keys())
            self.assertIsNone(overflow)
            self.assertEqual(body.count('Fleet follow-ups'), 2)
            sizes.add(len(body))
        self.assertEqual(len(sizes), 1)

    def test_passing_human_row_is_evidence_without_a_collector_task(self):
        self.data['repositories'][0]['reconcile'] = [
            {'item': 'app-install', 'probe': 'pass: token minted', 'action': 'none',
             'class': 'human-only', 'task': 'Install the CI App'}]
        self.invoke()
        self.assertIn('pass: token minted', self.load()['sample/app#2']['body'])
        self.assertNotIn('Human follow-up', self.state['sample/app#2']['body'])
        self.assertNotIn('Install the CI App', self.state['sample/app#2']['body'])
        self.assertCountEqual(self.writes(), ['edit demo/fleet#1', 'edit sample/app#2'])

    def test_embedded_source_text_does_not_merge_distinct_tasks(self):
        self.add_humans()
        row = self.data['repositories'][0]
        row['reconcile'][0]['task'] = 'Copy settings (from #12) into production'
        other = copy.deepcopy(row)
        other.update(repository='other/app', tracking_issue={'repo': 'other/app', 'number': 3}, skills_pin=None)
        other['reconcile'][0]['task'] = 'Copy settings (from #12) into staging'
        self.data['repositories'].append(other)
        self.state['other/app#3'] = dict(self.state['sample/app#2'], number=3)
        self.save()
        self.invoke()
        current = self.load()
        body = current['demo/fleet#8']['body']
        self.assertIn('into production', current['sample/app#2']['body'])
        self.assertIn('into staging', current['other/app#3']['body'])
        self.assertEqual(body.count('<!-- fleet-human:'), 2)
        self.assertIn('from sample/app#2', body)
        self.assertIn('from other/app#3', body)
        row['reconcile'][0]['probe'] = 'a changed probe'
        self.invoke()
        self.assertEqual(self.load()['demo/fleet#8']['body'], body)

    def test_legacy_reporter_row_survives_whitespace_change_and_marker_loss(self):
        for remove_marker in (False, True):
            with self.subTest(remove_marker=remove_marker):
                self.setUp()
                self.add_humans()
                collector = self.state['demo/fleet#8']
                marker = report.human_marker('sample/app', 2, 'Install the CI App')
                line = ('- [x] [HUMAN] Install the CI App — probe: token mint failed '
                        f'(from sample/app#2; item: app-install) <!-- fleet-human:{marker} -->')
                body = collector['body'].replace('- [x] [HUMAN] Previous task', line)
                if remove_marker:
                    body = re.sub(r' <!-- fleet-human:[^<>]+ -->', '', body)
                collector['body'] = body
                collector['state'] = 'CLOSED'
                collector['stateReason'] = 'COMPLETED'
                self.save()
                self.data['repositories'][0]['reconcile'][0]['task'] = 'Install the  CI App'
                self.invoke()
                current = self.load()['demo/fleet#8']
                self.assertEqual(current['body'], body)
                self.assertEqual(current['state'], 'CLOSED')
                self.assertIn('- [x] [HUMAN] Install the CI App', body)

    def test_human_edit_with_marker_repends_the_same_line(self):
        self.add_humans()
        self.invoke()
        self.load()
        body = self.state['demo/fleet#8']['body'].replace(
            '- [ ] [HUMAN] Fleet follow-ups', '- [x] [HUMAN] Human revised wording')
        self.state['demo/fleet#8']['body'] = body
        self.save()
        self.data['repositories'][0]['reconcile'][0]['probe'] = 'new evidence'
        self.invoke()
        updated = self.load()['demo/fleet#8']['body']
        self.assertEqual(updated.count('Fleet follow-ups'), 1)
        self.assertIn('- [ ] [HUMAN] Fleet follow-ups', updated)
        self.assertNotIn('Human revised wording', updated)

    def test_ambiguous_collector_syntax_refuses_without_writes(self):
        for fragment in ('---', '===', '   ## Provenance', '##\tProvenance',
                         '```markdown', '<div>', '> ## Heading', 'Provenance\n---',
                         '## Acceptance criteria ', '## Acceptance Criteria'):
            with self.subTest(fragment=fragment):
                self.add_humans()
                collector = self.state['demo/fleet#8']
                collector['body'] = collector['body'].replace('## Provenance', fragment + '\n## Provenance')
                before = collector['body']
                self.save()
                result = self.invoke(success=False)
                self.assertIn('ambiguous collector boundary syntax', result.stderr)
                self.assertEqual(self.load()['demo/fleet#8']['body'], before)
                self.assertEqual(self.writes(), [])

    def test_escaped_backticks_and_owner_slugs_survive_repeated_collector_writes(self):
        self.add_humans()
        row = self.data['repositories'][0]
        row.update(repository='_sample/app', tracking_issue={'repo': '_sample/app', 'number': 2}, skills_pin=None)
        row['reconcile'][0]['task'] = 'Run `gh auth` setup'
        row['reconcile'][0]['probe'] = 'probe `gh` failed\u2028retry'
        issue = self.state.pop('sample/app#2')
        issue['body'] = issue['body'].replace('sample/app#2', '_sample/app#2')
        self.state['_sample/app#2'] = issue
        self.save()
        self.invoke()
        body = self.load()['demo/fleet#8']['body']
        self.assertIn('### _sample\n\n- [ ] [HUMAN] Fleet follow-ups', body)
        self.assertIn('Run \\`gh auth\\` setup', self.state['_sample/app#2']['body'])
        count = len(self.writes())
        self.invoke()
        self.assertEqual(len(self.writes()), count)
        self.assertEqual(self.load()['demo/fleet#8']['body'], body)

    def test_crlf_collector_append_preserves_line_endings(self):
        self.add_humans()
        collector = self.state['demo/fleet#8']
        collector['body'] = collector['body'].replace('\n', '\r\n')
        self.save()
        self.invoke()
        body = self.load()['demo/fleet#8']['body']
        self.assertIn('### sample\r\n\r\n- [ ] [HUMAN] Fleet follow-ups', body)
        self.assertNotIn('\n', body.replace('\r\n', ''))
        self.assertNotIn('\r', body.replace('\r\n', ''))

    def test_mixed_line_endings_refuse(self):
        self.add_humans()
        collector = self.state['demo/fleet#8']
        collector['body'] = collector['body'].replace('## Acceptance criteria\n',
                                                       '## Acceptance criteria\r\n')
        self.save()
        result = self.invoke(success=False)
        self.assertIn('ambiguous collector boundary mixed line endings', result.stderr)
        self.assertEqual(self.writes(), [])

    def test_non_markdown_line_separators_refuse(self):
        for separator in ('\r', '\x85', '\u2028'):
            with self.subTest(separator=separator):
                self.add_humans()
                collector = self.state['demo/fleet#8']
                collector['body'] = collector['body'].replace('## Acceptance criteria',
                    'prefix' + separator + '## Acceptance criteria')
                self.save()
                result = self.invoke(success=False)
                self.assertIn('ambiguous collector boundary line ending', result.stderr)
                self.assertEqual(self.writes(), [])

    def test_thematic_break_after_task_or_heading_refuses(self):
        for anchor in ('- [x] [HUMAN] Previous task', '## Acceptance criteria'):
            with self.subTest(anchor=anchor):
                self.add_humans()
                collector = self.state['demo/fleet#8']
                collector['body'] = collector['body'].replace(anchor + '\n', anchor + '\n---\n')
                before = collector['body']
                self.save()
                result = self.invoke(success=False)
                self.assertIn('ambiguous collector boundary syntax', result.stderr)
                self.assertEqual(self.load()['demo/fleet#8']['body'], before)
                self.assertEqual(self.writes(), [])

    def test_collector_missing_or_ambiguous_is_actionable_without_writes(self):
        self.add_humans()
        other = copy.deepcopy(self.state['demo/fleet#8'])
        del self.state['demo/fleet#8']
        self.save()
        self.assertIn('provision lazily through track-work', self.invoke(success=False).stderr)
        self.assertEqual(self.writes(), [])
        self.state['demo/fleet#8'] = other
        self.state['demo/fleet#9'] = dict(other, number=9)
        self.save()
        self.assertIn('duplicate open collectors', self.invoke(success=False).stderr)
        self.assertEqual(self.writes(), [])

    def test_completed_collector_is_reopened_not_duplicated(self):
        self.add_humans()
        self.state['demo/fleet#8'].update(state='CLOSED', stateReason='COMPLETED', closedAt='2026-10-01')
        self.save()
        self.invoke()
        self.assertEqual(self.writes(), ['edit demo/fleet#1', 'edit sample/app#2', 'reopen demo/fleet#8',
                                         'edit demo/fleet#8', 'edit sample/app#2'])
        self.assertEqual(self.load()['demo/fleet#8']['state'], 'OPEN')

    def test_identical_rerun_preserves_every_tick_without_writes(self):
        self.add_humans()
        self.add_tracking_issue('sample/later')
        self.save()
        self.invoke()
        self.load()
        self.state['demo/fleet#8'].update(state='CLOSED', stateReason='COMPLETED', closedAt='2026-10-01')
        body = self.state['demo/fleet#8']['body']
        self.state['demo/fleet#8']['body'] = body.replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
        self.save()
        before = copy.deepcopy(self.state)
        count = len(self.writes())
        self.invoke()
        self.assertEqual(len(self.writes()), count)
        self.assertEqual(self.load(), before)

    def test_bad_collector_scope_or_parent_and_missing_markers_do_not_append(self):
        self.add_humans()
        self.state['demo/fleet#8']['parent'] = {'url': 'https://github.com/other/project/issues/1'}
        self.save()
        self.invoke(success=False)
        self.assertEqual(self.writes(), [])
        self.state['demo/fleet#8']['parent'] = {'url': 'https://github.com/demo/fleet/issues/1'}
        self.state['sample/app#2']['body'] = 'no marker'
        self.save()
        self.invoke(success=False)
        self.assertEqual(self.writes(), [])

    def test_prior_lookup_skips_ineligible_collectors_without_reads(self):
        self.add_humans()
        candidates = []
        for number, body, state, reason in (
            (11, 'no scope', 'OPEN', ''),
            (12, 'Collector scope: milestone 2', 'CLOSED', 'NOT_PLANNED'),
            (13, 'Collector scope: malformed', 'OPEN', ''),
        ):
            issue = copy.deepcopy(self.state['demo/fleet#8'])
            issue.update(number=number, body=body, state=state, stateReason=reason)
            candidates.append(issue)
        class Gh:
            def __init__(self, issue):
                self.original = issue
                self.reads = []
            def read(self, *args):
                return candidates + [self.original]
            def issue(self, ref):
                self.reads.append(ref['number'])
                return self.original
        gh = Gh(self.state['demo/fleet#8'])
        ref, _ = report.find_collector(gh, self.data, self.state['demo/fleet#1'])
        self.assertEqual(ref['number'], 8)
        self.assertEqual(set(gh.reads), {8})

    def test_markerless_reporter_probe_delimiters_keep_identity(self):
        for probe in ('first — probe: second', 'first  —  probe: second'):
            with self.subTest(probe=probe):
                task = ('[HUMAN] Install the CI App  —  probe: ' + probe
                        + ' (from sample/app#2; item: setup)')
                expected = report.task_key('[HUMAN] Install the CI App (from sample/app#2)', 'demo/fleet')
                self.assertEqual(report.task_key(task, 'demo/fleet'), expected)

    def test_existing_task_stays_on_collector_after_milestone_change(self):
        self.add_humans()
        self.invoke()
        self.load()
        old = self.state['demo/fleet#8']
        old['body'] = old['body'].replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
        old_body = old['body']
        source_body = self.state['sample/app#2']['body']
        self.state['demo/fleet#1']['milestone'] = {'number': 6}
        new = copy.deepcopy(old)
        new.update(number=9, milestone={'number': 6})
        new['body'] = ('## Acceptance criteria\n\n## Provenance\n\n'
                       'Collector scope: milestone 6\n')
        self.state['demo/fleet#9'] = new
        self.save()
        self.invoke()
        current = self.load()
        self.assertEqual(current['demo/fleet#8']['body'], old_body)
        self.assertEqual(current['demo/fleet#9']['body'], new['body'])
        self.assertEqual(current['sample/app#2']['body'], source_body)

    def test_escaped_source_in_probe_and_item_cannot_spoof_suffix(self):
        self.add_humans()
        item = self.data['repositories'][0]['reconcile'][0]
        item['probe'] = 'evidence (from fake/repo#9; item: trap)'
        item['item'] = 'real (from fake/repo#8; item: trap)'
        collector = self.state['demo/fleet#8']
        legacy = (f"- [x] [HUMAN] {report.text(item['task'])} — probe: {report.text(item['probe'])} "
                  f"(from sample/app#2; item: {report.text(item['item'])})")
        collector['body'] = collector['body'].replace('- [x] [HUMAN] Previous task', legacy)
        before = collector['body']
        self.save()
        self.invoke()
        self.assertEqual(self.load()['demo/fleet#8']['body'], before)
        self.assertIsNone(report.task_key(r'[HUMAN] task \(from fake/repo#9\)', 'demo/fleet'))

    def test_milestone_scope_and_ordinary_existing_task(self):
        self.add_humans()
        self.state['demo/fleet#1']['milestone'] = {'number': 6}
        collector = self.state['demo/fleet#8']
        collector['milestone'] = {'number': 6}
        collector['body'] = collector['body'].replace('Collector scope: demo/fleet#1', 'Collector scope: milestone 6')
        collector['body'] = collector['body'].replace('- [x] [HUMAN] Previous task',
            '- [x] [HUMAN] Install the CI App (from sample/app#2)')
        self.save()
        self.invoke()
        body = self.load()['demo/fleet#8']['body']
        self.assertEqual(body.count('Install the CI App'), 1)
        self.assertIn('- [x] [HUMAN] Install', body)
        self.assertNotIn('edit demo/fleet#8', self.writes())

    def test_normal_task_with_local_source_stays_ticked_and_closed(self):
        self.add_humans()
        row = self.data['repositories'][0]
        row['repository'] = 'demo/fleet'
        row['tracking_issue'] = {'repo': 'demo/fleet', 'number': 2}
        row['skills_pin'] = None
        row['reconcile'][0]['task'] = 'Add FLY_API_TOKEN  to repo secrets'
        self.state['demo/fleet#2'] = self.state.pop('sample/app#2')
        collector = self.state['demo/fleet#8']
        collector.update(state='CLOSED', stateReason='COMPLETED', closedAt='2026-10-01')
        collector['body'] = collector['body'].replace('Previous task',
            'Add FLY_API_TOKEN to repo secrets (from #2)')
        self.save()
        self.invoke()
        current = self.load()['demo/fleet#8']
        self.assertEqual(current, collector)
        self.assertFalse(any('demo/fleet#8' in line for line in self.writes()))
        # Fully qualified sources compare owner and repository without case.
        collector['body'] = collector['body'].replace('(from #2)', '(from Demo/Fleet#2)')
        self.state['demo/fleet#8'] = collector
        self.save()
        self.invoke()
        self.assertEqual(self.load()['demo/fleet#8'], collector)

    def test_owner_heading_in_provenance_is_ignored(self):
        self.add_humans()
        collector = self.state['demo/fleet#8']
        collector['body'] += '\n### sample\n\nLeave provenance here.\n'
        provenance = collector['body'].split('## Provenance')[1]
        self.save()
        self.invoke()
        body = self.load()['demo/fleet#8']['body']
        self.assertIn('### sample\n\n- [ ] [HUMAN] Fleet follow-ups', body.split('## Provenance')[0])
        self.assertEqual(body.split('## Provenance')[1], provenance)

    def test_missing_acceptance_section_refuses_even_with_owner_heading(self):
        self.add_humans()
        collector = self.state['demo/fleet#8']
        collector['body'] = collector['body'].replace('## Acceptance criteria', '### sample')
        self.save()
        result = self.invoke(success=False)
        self.assertIn('collector must have one Acceptance criteria section', result.stderr)
        self.assertEqual(self.writes(), [])

    def test_capitalized_scope_and_parent_validate(self):
        self.add_humans()
        self.data['run']['epic']['repo'] = 'Demo/Fleet'
        collector = self.state['demo/fleet#8']
        collector['body'] = collector['body'].replace('demo/fleet#1', 'Demo/Fleet#1')
        collector['parent']['url'] = 'https://github.com/Demo/Fleet/issues/1'
        self.save()
        self.invoke()
        self.assertIn('edit demo/fleet#8', self.writes())

    def test_render_previews_exact_written_bodies_including_human_followups(self):
        self.add_humans()
        self.state['sample/app#2']['body'] += '\n## Out of scope\n\nExisting exclusions.\n'
        self.save()
        preview = json.loads(self.invoke('render').stdout)['reports']
        self.assertEqual(self.writes(), [])
        source = preview[1]['body']
        self.assertIn('### Out of scope\n\nHuman follow-up', source)
        self.assertEqual(source.count('\n## Out of scope\n'), 1)
        self.assertLess(source.index('### Out of scope'), source.index(':repository:end -->'))
        self.invoke()
        current = self.load()
        for item in preview:
            repo, number = report.reference(item['issue'])
            self.assertEqual(item['body'], current[f'{repo}#{number}']['body'])

    def test_same_task_from_two_probe_rows_is_appended_once(self):
        self.add_humans()
        row = self.data['repositories'][0]
        row['devcontainer'] = [dict(row['reconcile'][0], item='image', probe='another observation')]
        self.invoke()
        self.assertIn('1 follow-up at', self.load()['demo/fleet#8']['body'])

    def add_tracking_issue(self, repo):
        row = copy.deepcopy(self.data['repositories'][0])
        row.update(repository=repo, tracking_issue={'repo': repo, 'number': 2}, skills_pin=None)
        self.data['repositories'].append(row)
        self.state[f'{repo}#2'] = copy.deepcopy(self.state['sample/app#2'])

    def test_large_fleet_writes_every_body_within_limit(self):
        self.add_humans()
        first = self.data['repositories'][0]
        first['reconcile'] = [
            {'item': f'catalog-check-{index}', 'probe': 'manual: ' + 'evidence ' * 16,
             'action': 'none', 'class': 'human-only', 'task': f'Complete setup {index}'}
            for index in range(96)
        ]
        first['reconcile'][0]['probe'] = 'pass: setup is complete'
        first['reconcile'][1]['probe'] = 'unknown: ' + 'probe unavailable ' * 8
        for index in range(7):
            self.add_tracking_issue(f'sample/extra-{index}')
        self.save()

        # The old epic and collector both repeated these distinct tasks' probe
        # text in full. Their probe text alone exceeded the limit.
        old_epic_probe_chars = sum(len(item['probe']) for row in self.data['repositories']
                                   for item in row['reconcile'])
        old_collector_probe_chars = sum(len(item['probe']) for row in self.data['repositories']
                                        for item in report.human_rows(row))
        self.assertGreater(min(old_epic_probe_chars, old_collector_probe_chars), 65_536)
        self.invoke()
        current = self.load()
        trackers = [f'edit {key}' for key in sorted(current) if key.startswith('sample/')]
        self.assertEqual(self.writes(), ['edit demo/fleet#1', *trackers, 'edit demo/fleet#8', *trackers])
        for key, issue in current.items():
            self.assertLessEqual(len(issue['body']), 65_536, key)
        epic = current['demo/fleet#1']['body']
        collector = current['demo/fleet#8']['body']
        self.assertNotIn('catalog-check-', epic)
        self.assertNotIn('Complete setup', collector)
        self.assertEqual(collector.count('95 follow-ups at '), 8)
        for row in self.data['repositories']:
            ref = row['tracking_issue']
            link = report.issue_link(ref)
            self.assertIn(f'pass 1, manual 94, unknown 1 · {link}', epic)
            self.assertIn(f'95 follow-ups at {link}', collector)
            detail = current[f"{ref['repo']}#{ref['number']}"]['body']
            self.assertIn('catalog-check-95', detail)
            self.assertIn('Complete setup 95', detail)

    def test_oversized_target_does_not_stop_later_writes(self):
        cases = (('demo/fleet#8', False), ('demo/fleet#1', False),
                 ('sample/app#2', False), ('sample/app#2', True))
        for target, prior in cases:
            with self.subTest(target=target, prior=prior):
                self.setUp()
                self.add_humans()
                old_line = None
                if prior:
                    self.invoke()
                    collector = self.load()['demo/fleet#8']
                    collector['body'] = collector['body'].replace('- [ ] [HUMAN] Fleet', '- [x] [HUMAN] Fleet')
                    old_line = next(line for line in collector['body'].splitlines() if 'from sample/app#2' in line)
                    self.data['repositories'][0]['reconcile'].append({
                        'item': 'second', 'probe': 'manual: new setup', 'action': 'none',
                        'class': 'human-only', 'task': 'Configure a second setting',
                    })
                    (self.root/'writes').unlink()
                self.add_tracking_issue('sample/later')
                issue = self.state[target]
                if target == 'demo/fleet#8':
                    issue.update(state='CLOSED', stateReason='COMPLETED')
                padding = 65_536 - len(issue['body']) - 2
                issue['body'] = 'P' * padding + '\n\n' + issue['body']
                original = copy.deepcopy(issue)
                self.save()

                preview = json.loads(self.invoke('render').stdout)['reports']
                result = self.invoke(success=False)
                self.assertEqual(result.returncode, 2)
                self.assertIn(f'skipped oversized body for {target}', result.stderr)
                expected = [f'edit {key}' for key in self.state if key != target]
                if target != 'demo/fleet#8':
                    expected += [f'edit {key}' for key in self.state if key.startswith('sample/') and key != target]
                self.assertCountEqual(self.writes(), expected)
                current = self.load()
                self.assertEqual(current[target], original)
                for entry in preview:
                    repo, number = report.reference(entry['issue'])
                    if f'{repo}#{number}' != target:
                        self.assertEqual(current[f'{repo}#{number}']['body'], entry['body'])
                later = current['sample/later#2']['body']
                self.assertIn('sample/later', later)
                if target == 'demo/fleet#8':
                    self.assertIn('publication pending in [demo/fleet#8]', later)
                    self.assertNotIn('tracked in [demo/fleet#8]', later)
                else:
                    self.assertIn('tracked in [demo/fleet#8]', later)
                if target == 'sample/app#2':
                    source_lines = [line for line in current['demo/fleet#8']['body'].splitlines()
                                    if 'from sample/app#2' in line]
                    self.assertEqual(source_lines, [old_line] if old_line else [])
                    self.assertIn('from sample/later#2', current['demo/fleet#8']['body'])

    def test_body_limit_boundaries(self):
        for char, size, fits in (('P', 65_536, True), ('P', 65_537, False), ('🛠', 65_500, True)):
            with self.subTest(char=char, size=size):
                self.setUp()
                target = 'demo/fleet#1'
                preview = json.loads(self.invoke('render').stdout)['reports'][0]['body']
                prefix = char * (size - len(preview) - 2) + '\n\n'
                issue = self.state[target]
                issue['body'] = prefix + issue['body']
                before = issue['body']
                self.save()

                result = self.invoke(success=fits)
                stored = self.load()[target]['body']
                if fits:
                    self.assertEqual(stored, prefix + preview)
                    self.assertIn(f'edit {target}', self.writes())
                    if char != 'P':
                        self.assertGreater(len(stored.encode('utf-8')), 65_536)
                else:
                    self.assertEqual(stored, before)
                    self.assertNotIn(f'edit {target}', self.writes())
                    self.assertIn(f'{target} ({size} characters', result.stderr)

    def test_reopen_rechecks_a_now_oversized_collector(self):
        self.add_humans()
        collector = self.state['demo/fleet#8']
        collector.update(state='CLOSED', stateReason='COMPLETED')
        body = collector['body']
        self.save()
        (self.root/'grow-on-reopen').touch()

        result = self.invoke(success=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('skipped oversized body for demo/fleet#8', result.stderr)
        self.assertEqual(self.writes(), ['edit demo/fleet#1', 'edit sample/app#2', 'reopen demo/fleet#8'])
        current = self.load()
        self.assertEqual(current['demo/fleet#8']['body'], 'P' * (65_536 - len(body) - 2) + '\n\n' + body)
        self.assertIn('publication pending in [demo/fleet#8]', current['sample/app#2']['body'])

    def test_other_closed_collector_is_not_reopened(self):
        self.add_humans()
        self.state['demo/fleet#8'].update(state='CLOSED', stateReason='NOT_PLANNED')
        self.save()
        self.invoke(success=False)
        self.assertEqual(self.writes(), [])

    def test_documented_transition_commands_are_wired(self):
        skill = ASSETS.parent
        for path in (skill/'SKILL.md', ASSETS/'fleet-lane-brief.md'):
            content = path.read_text()
            self.assertIn('each lane transition', content)
            self.assertIn('after its reconcile writes and re-probes', content)
            self.assertIn('python3 assets/fleet-report.py write --input /path/to/run-report.json', content)

    def test_invalid_input_and_failed_reads_or_writes_are_nonzero(self):
        self.data['repositories'][0]['non_adoption_count'] = 9
        self.invoke(success=False)
        self.assertEqual(self.writes(), [])
        del self.data['repositories'][0]['non_adoption_count']
        (self.root/'fail-read').touch()
        self.invoke(success=False)
        self.assertEqual(self.writes(), [])
        (self.root/'fail-read').unlink()
        (self.root/'fail-write').touch()
        self.invoke(success=False)

    def test_reports_tracker_and_collector_failures_in_the_same_run(self):
        self.add_humans()
        self.add_tracking_issue('sample/later')
        self.save()
        (self.root/'fail-target').write_text('sample/later#2\ndemo/fleet#8\n')

        result = self.invoke(success=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('could not publish sample/later#2', result.stderr)
        self.assertIn('could not publish collector demo/fleet#8', result.stderr)
        self.assertEqual(self.writes(), ['edit demo/fleet#1', 'edit sample/app#2', 'edit sample/later#2',
                                         'edit demo/fleet#8'])

    def test_probe_and_answer_data_cannot_create_markers_or_checkboxes(self):
        self.data['repositories'][0]['answers_changed'][0]['after'] = '@name <!-- fake -->\n- [x] done | row'
        body = json.loads(self.invoke('render').stdout)['reports'][1]['body']
        self.assertNotIn('<!-- fake -->', body)
        self.assertNotIn('\n- [x] done', body)
        self.assertIn('\\| row', body)
        self.assertIn('\\@name', body)


if __name__ == '__main__':
    if len(sys.argv) == 3:
        epic, tracking = map(Path, sys.argv[1:])
        case = FleetReportTests()
        case.runTest = lambda: case.write_receipt_verified_bodies(epic, tracking)
        sys.exit(not unittest.TextTestRunner().run(case).wasSuccessful())
    else:
        unittest.main()
PY

if [ "$#" -eq 0 ]; then
    "$asset_dir/test-devcontainer-probe.sh"
    "$asset_dir/test-reconcile-probe.sh"
fi
