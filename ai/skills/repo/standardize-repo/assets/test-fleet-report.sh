#!/usr/bin/env bash
# Offline behavior tests; the Python stub never calls GitHub.
set -euo pipefail
asset_dir="$(cd "$(dirname "$0")" && pwd)"
python3 -B - "$asset_dir" <<'PY'
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
ASSETS = Path(sys.argv.pop())
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
    if operation == 'edit':
        assert a[-2:] == ['--body-file', '-']
        state[key]['body'] = sys.stdin.read()
    else:
        state[key]['state'] = 'OPEN'
        state[key]['stateReason'] = ''
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
        self.assertIn('### sample\n\n- [ ] [HUMAN] Install the CI App', body)
        self.assertIn('- [x] [HUMAN] Previous task', body)
        self.assertIn('from sample/app#2', body)
        self.assertIn('token mint failed', body)
        source = current['sample/app#2']['body']
        self.assertIn('Human follow-up (tracked in [demo/fleet#8]', source)
        count = len(self.writes())
        self.invoke()
        self.assertEqual(len(self.writes()), count)
        # A human's tick remains checked and newer probe evidence must not duplicate the task.
        self.state['demo/fleet#8']['body'] = body.replace('- [ ] [HUMAN] Install', '- [x] [HUMAN] Install')
        self.save()
        self.data['repositories'][0]['reconcile'][0]['probe'] = 'still missing'
        self.invoke()
        body = self.load()['demo/fleet#8']['body']
        self.assertEqual(body.count('Install the CI App'), 1)
        self.assertIn('- [x] [HUMAN] Install', body)

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
        body = self.load()['demo/fleet#8']['body']
        self.assertIn('into production', body)
        self.assertIn('into staging', body)
        self.assertEqual(body.count('<!-- fleet-human:'), 2)
        self.assertIn('from sample/app#2', body)
        self.assertIn('from other/app#3', body)
        row['reconcile'][0]['probe'] = 'a changed probe'
        self.invoke()
        self.assertEqual(self.load()['demo/fleet#8']['body'], body)

    def test_reporter_row_survives_whitespace_change_and_marker_loss(self):
        for remove_marker in (False, True):
            with self.subTest(remove_marker=remove_marker):
                self.setUp()
                self.add_humans()
                self.invoke()
                self.load()
                collector = self.state['demo/fleet#8']
                body = collector['body'].replace('- [ ] [HUMAN] Install', '- [x] [HUMAN] Install')
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

    def test_human_edit_with_marker_keeps_reporter_identity(self):
        self.add_humans()
        self.invoke()
        self.load()
        body = self.state['demo/fleet#8']['body'].replace(
            '- [ ] [HUMAN] Install the CI App', '- [x] [HUMAN] Human revised wording')
        self.state['demo/fleet#8']['body'] = body
        self.save()
        self.data['repositories'][0]['reconcile'][0]['probe'] = 'new evidence'
        self.invoke()
        self.assertEqual(self.load()['demo/fleet#8']['body'], body)

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
        self.assertIn('### _sample\n\n- [ ] [HUMAN] Run \\`gh auth\\` setup', body)
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
        self.assertIn('### sample\r\n\r\n- [ ] [HUMAN] Install', body)
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
        self.assertEqual(self.writes()[0], 'reopen demo/fleet#8')
        self.assertEqual(self.load()['demo/fleet#8']['state'], 'OPEN')

    def test_unchanged_completed_collector_is_not_reopened(self):
        self.add_humans()
        self.invoke()
        self.load()
        self.state['demo/fleet#8'].update(state='CLOSED', stateReason='COMPLETED', closedAt='2026-10-01')
        body = self.state['demo/fleet#8']['body']
        self.state['demo/fleet#8']['body'] = body.replace('- [ ] [HUMAN] Install', '- [x] [HUMAN] Install')
        self.save()
        count = len(self.writes())
        self.invoke()
        self.assertEqual(len(self.writes()), count)
        self.assertEqual(self.load()['demo/fleet#8']['state'], 'CLOSED')

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
        old['body'] = old['body'].replace('- [ ] [HUMAN] Install', '- [x] [HUMAN] Install')
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
        self.invoke()
        self.load()
        collector = self.state['demo/fleet#8']
        collector['body'] = re.sub(r' <!-- fleet-human:[^<>]+ -->', '', collector['body'])
        collector['body'] = collector['body'].replace('- [ ] [HUMAN] Install', '- [x] [HUMAN] Install')
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
        self.assertIn('### sample\n\n- [ ] [HUMAN] Install', body.split('## Provenance')[0])
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
        self.assertEqual(self.load()['demo/fleet#8']['body'].count('Install the CI App'), 1)

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

    def test_probe_and_answer_data_cannot_create_markers_or_checkboxes(self):
        self.data['repositories'][0]['answers_changed'][0]['after'] = '@name <!-- fake -->\n- [x] done | row'
        body = json.loads(self.invoke('render').stdout)['reports'][1]['body']
        self.assertNotIn('<!-- fake -->', body)
        self.assertNotIn('\n- [x] done', body)
        self.assertIn('\\| row', body)
        self.assertIn('\\@name', body)


if __name__ == '__main__':
    unittest.main()
PY

"$asset_dir/test-devcontainer-probe.sh"
