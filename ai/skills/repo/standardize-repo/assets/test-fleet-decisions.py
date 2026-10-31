#!/usr/bin/env python3
"""Offline behavioral tests for fleet decisions and the fleet brief contract."""

import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ASSETS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fleet_decisions', ASSETS / 'fleet-decisions.py')
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)


def tearDownModule():
    if (ASSETS / '__pycache__').exists():
        raise AssertionError('fleet decisions tests must not leave __pycache__ in assets')


class DecisionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fleet-decisions-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'decisions.yaml'
        self.example = subprocess.check_output(
            ['yq', '-o=json', '.', str(ASSETS / 'fleet-decisions.example.yaml')], text=True)
        self.data = json.loads(self.example)

    def run_cli(self, data=None, *args, raw=None):
        self.path.write_text(raw if raw is not None else json.dumps(data))
        return subprocess.run(['python3', str(ASSETS / 'fleet-decisions.py'), str(self.path), *args],
                              capture_output=True, text=True)

    def test_real_yaml_and_all_scope_citations(self):
        result = self.run_cli(None, '--release', 'v0.0.0-example', '--repository',
                              'EXAMPLE-owner/example-repository', '--require', 'FLEET-QUESTIONS',
                              '--require', 'RELEASE-SECURITY', '--require', 'REPO-ANSWERS',
                              raw=(ASSETS / 'fleet-decisions.example.yaml').read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e['id'] for e in json.loads(result.stdout)['decisions']],
                         ['FLEET-QUESTIONS', 'RELEASE-SECURITY', 'REPO-ANSWERS'])

    def test_multi_word_ruling_passes(self):
        self.data['fleet'][0]['ruling'] = 'Keep all existing security checks enabled.'
        result = self.run_cli(self.data)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_structured_answers_validated_on_load_and_lane_lookup(self):
        valid = dict(target_release='v1', scope={'kind': 'fleet'}, copier_answers={'project_name': 'Repo'},
                     reconcile_classes=['agent-apply', 'agent-apply-with-fleet-approval'], skills_sync='absorb',
                     legacy_baseline=True, guarded_rollback=True, model_rulings={'lane': 'policy-default'},
                     review_exclusions=['example/**'])
        invalid = [
            ('target_release', 'v-other'), ('target_release', None),
            ('scope', 'fleet'), ('scope', {'kind': 'fleet', 'extra': True}),
            ('scope', {'kind': 'wave', 'wave': True}), ('scope', {'kind': 'wave', 'wave': 0}),
            ('scope', {'kind': 'repository', 'repository': 'bad-name'}),
            ('copier_answers', []), ('copier_answers', {'_commit': 'x'}),
            ('copier_answers', {'': True}), ('copier_answers', {' ': True}),
            ('reconcile_classes', 'agent-apply'), ('reconcile_classes', ['human-only']),
            ('reconcile_classes', [True]), ('skills_sync', 'per-lane'),
            ('legacy_baseline', 'yes'), ('legacy_baseline', 1),
            ('guarded_rollback', 'false'), ('guarded_rollback', 0),
            ('model_rulings', []), ('review_exclusions', 'all'),
            ('review_exclusions', [' ']), ('review_exclusions', [1]),
        ]

        def document(key, answer):
            entry = dict(id='STRUCTURED', scope='repository' if key == 'copier_answers' else 'release',
                         ruling=json.dumps(dict(schema_version=1, key=key, answer=answer)),
                         approved_by='maintainer', approved_on='2026-10-30')
            if key == 'copier_answers':
                entry['repository'] = 'example/one'
            return {'schema_version': 1, 'fleet': [], 'releases': {'v1': [entry]}}

        for key, answer in valid.items():
            with self.subTest(valid_key=key):
                for args in ((), ('--release', 'v1', '--repository', 'example/one', '--require-key', key)):
                    result = self.run_cli(document(key, answer), *args)
                    self.assertEqual(result.returncode, 0, result.stderr)
        for key, answer in invalid:
            with self.subTest(key=key, answer=answer):
                for args in ((), ('--release', 'v1', '--repository', 'example/one', '--require-key', key)):
                    result = self.run_cli(document(key, answer), *args)
                    self.assertEqual(result.returncode, 1, result.stdout)
                    self.assertIn(key, result.stderr)
                    self.assertEqual(result.stdout, '')

        for key, answer in valid.items():
            for scope in ('release', 'repository', 'fleet'):
                expected = 'repository' if key == 'copier_answers' else 'release'
                if scope == expected:
                    continue
                with self.subTest(key=key, wrong_scope=scope):
                    data = document(key, answer)
                    entry = data['releases']['v1'].pop()
                    entry['scope'] = scope
                    entry.pop('repository', None)
                    if scope == 'repository':
                        entry['repository'] = 'example/one'
                    (data['fleet'] if scope == 'fleet' else data['releases']['v1']).append(entry)
                    for args in ((), ('--release', 'v1', '--repository', 'example/one', '--require-key', key)):
                        result = self.run_cli(data, *args)
                        self.assertEqual(result.returncode, 1)
                        self.assertIn('requires ' + expected + ' scope', result.stderr)
                        self.assertEqual(result.stdout, '')

    def test_reserved_payload_envelopes_fail_closed_and_legacy_json_survives(self):
        entry = dict(id='PAYLOAD', scope='release', approved_by='maintainer', approved_on='2026-10-30')
        for payload in ({'schema_version': 1, 'answer': False},
                        {'schema_version': 1, 'key': 'unknown', 'answer': False},
                        {'schema_version': True, 'key': 'skills_sync', 'answer': 'absorb'},
                        {'schema_version': 2, 'key': 'skills_sync', 'answer': 'absorb'},
                        {'schema_version': 1, 'key': 'skills_sync'},
                        {'schema_version': 1, 'key': [], 'answer': False}):
            with self.subTest(payload=payload):
                data = {'schema_version': 1, 'fleet': [], 'releases': {'v1': [
                    {**entry, 'ruling': json.dumps(payload)}]}}
                for args in ((), ('--release', 'v1', '--repository', 'example/one', '--require-key', 'skills_sync')):
                    result = self.run_cli(data, *args)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('invalid start-of-run ruling payload', result.stderr)
                    self.assertEqual(result.stdout, '')
        for ruling in ('A free-form approval.', '{"other": "legacy JSON"}'):
            data = {'schema_version': 1, 'fleet': [], 'releases': {'v1': [{**entry, 'ruling': ruling}]}}
            result = self.run_cli(data, '--release', 'v1', '--repository', 'example/one', '--require', 'PAYLOAD')
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_legacy_reserved_key_object_is_opaque(self):
        ruling = json.dumps({'key': 'skills_sync', 'answer': 'absorb'})
        entry = dict(id='LEGACY', scope='release', ruling=ruling,
                     approved_by='maintainer', approved_on='2026-10-30')
        data = {'schema_version': 1, 'fleet': [], 'releases': {'v1': [entry]}}
        result = self.run_cli(data, '--release', 'v1', '--repository', 'example/one', '--require', 'LEGACY')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['decisions'][0]['ruling'], ruling)
        result = self.run_cli(data, '--release', 'v1', '--repository', 'example/one', '--require-key', 'skills_sync')
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing ruling key: skills_sync', result.stderr)

    def test_undecodable_json_rulings_remain_opaque_legacy_text(self):
        # Duplicate mappings are legal in a v1 ruling STRING. They cannot be
        # interpreted as start-of-run answers, even if a reserved key appears.
        # An unknown key without schema_version is also intentionally free-form.
        rulings = ('{"a":1,"a":2}', '{"other":{"a":1,"a":2}}',
                   '{"key":"scope","note":"x","note":"y"}',
                   '{"key":"legacy-note","note":"x"}')
        for ruling in rulings:
            with self.subTest(ruling=ruling):
                data = copy.deepcopy(self.data)
                data['fleet'][0]['ruling'] = ruling
                result = self.run_cli(data)
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.run_cli(data, '--release', 'v0.0.0-example', '--repository',
                                      'example-owner/example-repository', '--require', 'FLEET-QUESTIONS')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)['decisions'][0]['ruling'], ruling)
                result = self.run_cli(data, '--release', 'v0.0.0-example', '--repository',
                                      'example-owner/example-repository', '--require-key', 'scope')
                self.assertEqual(result.returncode, 1)
                self.assertIn('missing ruling key: scope', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_deep_free_form_rulings_never_emit_decoder_tracebacks(self):
        for ruling in ('[' * 100000, '[' * 2000 + '0' + ']' * 2000):
            with self.subTest(length=len(ruling)):
                data = copy.deepcopy(self.data)
                data['fleet'][0]['ruling'] = ruling
                for args in ((), ('--release', 'v0.0.0-example', '--repository',
                                  'example-owner/example-repository', '--require', 'FLEET-QUESTIONS')):
                    result = self.run_cli(data, *args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn('Traceback', result.stderr)
                    if args:
                        self.assertEqual(json.loads(result.stdout)['decisions'][0]['ruling'], ruling)
                result = self.run_cli(data, '--release', 'v0.0.0-example', '--repository',
                                      'example-owner/example-repository', '--require-key', 'scope')
                self.assertEqual(result.returncode, 1)
                self.assertIn('fleet-decisions:', result.stderr)
                self.assertIn('missing ruling key: scope', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_invalid_structures_and_provenance(self):
        cases = []
        for key in ('schema_version', 'fleet', 'releases'):
            item = copy.deepcopy(self.data)
            del item[key]
            cases.append(item)
        for value in (2, True, '1'):
            cases.append({**self.data, 'schema_version': value})
        cases.extend([{**self.data, 'unknown': True}, {**self.data, 'fleet': {}},
                      {**self.data, 'releases': []}])
        for key in ('id', 'scope', 'ruling', 'approved_by', 'approved_on'):
            item = copy.deepcopy(self.data)
            del item['fleet'][0][key]
            cases.append(item)
        for key, value in [('id', 'lowercase'), ('id', 'FLEET-QUESTIONS\n'),
                           ('ruling', '  '), ('approved_by', ''),
                           ('approved_on', '2026-02-30'), ('scope', 'release'),
                           ('repository', 'example/repo')]:
            item = copy.deepcopy(self.data)
            item['fleet'][0][key] = value
            cases.append(item)
        for value in ('bad-name', '', 'owner/repo/extra', 'owner/repo\n'):
            item = copy.deepcopy(self.data)
            item['releases']['v0.0.0-example'][1]['repository'] = value
            cases.append(item)
        item = copy.deepcopy(self.data)
        item['releases']['v0.0.0-example'][0]['scope'] = 'fleet'
        cases.append(item)
        for data in cases:
            with self.subTest(data=data):
                result = self.run_cli(data)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(str(self.path), result.stderr)
                self.assertEqual(result.stdout, '')

    def test_duplicate_ids_across_release_and_fleet(self):
        self.data['releases']['v0.0.0-example'][0]['id'] = 'FLEET-QUESTIONS'
        result = self.run_cli(self.data)
        self.assertEqual(result.returncode, 1)
        self.assertIn('duplicate decision ID: FLEET-QUESTIONS', result.stderr)

    def test_superseded_required_id_names_replacement(self):
        old = 'FLEET-QUESTIONS'
        replacement = copy.deepcopy(self.data['fleet'][0])
        replacement['id'] = 'FLEET-QUESTIONS-V2'
        replacement['supersedes'] = ['RELEASE-SECURITY']
        self.data['fleet'].append(replacement)
        result = self.run_cli(self.data, '--release', 'v0.0.0-example', '--repository',
                              'example-owner/example-repository', '--require', old,
                              '--require', 'RELEASE-SECURITY')
        self.assertEqual(result.returncode, 1)
        self.assertIn('RELEASE-SECURITY: superseded by FLEET-QUESTIONS-V2', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_supersession_missing_reference_and_cycles(self):
        cases = (
            (['MISSING'], 'supersedes missing ruling ID: MISSING'),
            (['FLEET-QUESTIONS'], 'supersession cycle involving FLEET-QUESTIONS'),
        )
        for references, message in cases:
            with self.subTest(references=references):
                item = copy.deepcopy(self.data)
                item['fleet'][0]['supersedes'] = references
                result = self.run_cli(item)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)

        item = copy.deepcopy(self.data)
        item['fleet'][0]['supersedes'] = ['RELEASE-SECURITY']
        item['releases']['v0.0.0-example'][0]['supersedes'] = ['FLEET-QUESTIONS']
        result = self.run_cli(item)
        self.assertEqual(result.returncode, 1)
        self.assertIn('supersession cycle involving', result.stderr)

    def test_yaml_duplicates_multiple_documents_and_malformed_input(self):
        for raw in ('schema_version: 1\nschema_version: 2\nfleet: []\nreleases: {}\n',
                    self.example + '\n---\n' + self.example, '[unclosed', ''):
            with self.subTest(raw=raw):
                self.assertEqual(self.run_cli(raw=raw).returncode, 1)

    def test_missing_or_inapplicable_ruling_stops_without_partial_output(self):
        for release, repository, required, message in (
            ('v0.0.0-example', 'example-owner/example-repository', 'MISSING-ANSWER', 'missing ruling ID: MISSING-ANSWER'),
            ('v-other', 'example-owner/example-repository', 'RELEASE-SECURITY', 'missing release rulings: releases.v-other'),
            ('v0.0.0-example', 'other/repo', 'REPO-ANSWERS', 'belongs to repository'),
        ):
            result = self.run_cli(self.data, '--release', release, '--repository', repository,
                                  '--require', 'FLEET-QUESTIONS', '--require', required)
            self.assertEqual(result.returncode, 1)
            self.assertIn(message, result.stderr)
            self.assertEqual(result.stdout, '')
        self.data['releases']['v-other'] = []
        result = self.run_cli(self.data, '--release', 'v-other', '--repository', 'example/repo',
                              '--require', 'RELEASE-SECURITY')
        self.assertEqual(result.returncode, 1)
        self.assertIn('belongs to release v0.0.0-example', result.stderr)

    def test_explicit_context_required_and_unreadable_path(self):
        result = self.run_cli(self.data, '--require', 'FLEET-QUESTIONS')
        self.assertEqual(result.returncode, 2)
        result = subprocess.run(['python3', str(ASSETS / 'fleet-decisions.py'),
                                 str(self.path.parent / 'missing.yaml')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing.yaml', result.stderr)

    def test_schema_changes_cannot_silently_add_unknown_vocabulary(self):
        with self.assertRaisesRegex(fleet.Invalid, 'unsupported schema keywords'):
            fleet.validate({}, {'type': 'object', 'not': {}})


class QuestionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fleet-questions-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.path = self.directory / 'decisions.yaml'
        self.path.write_text('schema_version: 1\nfleet: []\nreleases: {}\n')
        self.inventory = self.directory / 'inventory.yaml'
        self.inventory.write_text(json.dumps({'repositories': [
            {'repository': 'example/one', 'wave': 1},
            {'repository': 'example/two', 'wave': 2}]}))
        self.answers_file = self.directory / 'answers.json'

    def cli(self, *args):
        return subprocess.run(['python3', str(ASSETS / 'fleet-decisions.py'), str(self.path),
                               '--release', 'v1.0.0', *args], capture_output=True, text=True)

    def questions(self):
        result = self.cli('--questions', '--inventory', str(self.inventory))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def record(self, answers):
        self.answers_file.write_text(json.dumps(answers))
        return self.cli('--record-answers', str(self.answers_file), '--inventory', str(self.inventory),
                        '--approved-by', 'maintainer', '--approved-on', '2026-10-30')

    def test_all_defaults_record_and_lane_lookup(self):
        before = self.path.read_bytes()
        rendered = self.questions()
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual([q['key'] for q in rendered['questions']], [key for key, _ in fleet.QUESTIONS])
        answers = rendered['answers']
        self.assertEqual(answers, dict(target_release='v1.0.0', scope={'kind': 'fleet'},
                                      copier_answers={'example/one': {}, 'example/two': {}},
                                      reconcile_classes=[], skills_sync='merge-first', legacy_baseline=False,
                                      guarded_rollback=False, model_rulings={}, review_exclusions=[]))
        result = self.record(answers)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(self.path.read_text())
        self.assertEqual(data['schema_version'], 1)
        self.assertEqual(len(data['releases']['v1.0.0']), 10)
        for key, _ in fleet.QUESTIONS:
            result = self.cli('--repository', 'EXAMPLE/one', '--require-key', key)
            self.assertEqual(result.returncode, 0, result.stderr)
            entry = json.loads(result.stdout)['decisions'][0]
            self.assertEqual(entry['approved_by'], 'maintainer')
            self.assertEqual(entry['approved_on'], '2026-10-30')
            expected = {} if key == 'copier_answers' else answers[key]
            self.assertEqual(json.loads(entry['ruling'])['answer'], expected)

    def test_repo_changes_carried_forward_and_supersession(self):
        answers = self.questions()['answers']
        self.assertEqual(self.record(answers).returncode, 0)
        original = json.loads(self.path.read_text())['releases']['v1.0.0']
        answers['copier_answers']['example/two'] = {'use_codeql': False, 'project_name': 'New name'}
        answers['skills_sync'] = 'absorb'
        result = self.record(answers)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.questions()['answers'], answers)
        entries = json.loads(self.path.read_text())['releases']['v1.0.0']
        self.assertEqual(entries[:10], original)
        self.assertEqual({e['supersedes'][0] for e in entries[10:]}, {e['id'] for e in original})
        for repo, expected in answers['copier_answers'].items():
            result = self.cli('--repository', repo, '--require-key', 'copier_answers')
            entry = json.loads(result.stdout)['decisions'][0]
            self.assertEqual(json.loads(entry['ruling'])['answer'], expected)

    def test_missing_key_names_and_conflicting_answers(self):
        result = self.cli('--repository', 'example/one', '--require-key', 'skills_sync')
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing ruling key: skills_sync', result.stderr)
        answers = self.questions()['answers']
        self.assertEqual(self.record(answers).returncode, 0)
        data = json.loads(self.path.read_text())
        data['releases']['v1.0.0'] = [e for e in data['releases']['v1.0.0']
                                    if json.loads(e['ruling'])['key'] != 'skills_sync']
        self.path.write_text(json.dumps(data))
        result = self.cli('--repository', 'example/one', '--require-key', 'skills_sync')
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing ruling key: skills_sync', result.stderr)
        self.assertEqual(result.stdout, '')
        result = self.cli('--repository', 'other/repo', '--require-key', 'copier_answers')
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing ruling key: copier_answers.other/repo', result.stderr)
        duplicate = copy.deepcopy(data['releases']['v1.0.0'][0])
        duplicate['id'] = 'CONFLICT'
        data['releases']['v1.0.0'].append(duplicate)
        self.path.write_text(json.dumps(data))
        result = self.cli('--repository', 'example/one', '--require-key', 'target_release')
        self.assertEqual(result.returncode, 1)
        self.assertIn('conflicting ruling key: target_release', result.stderr)
        self.assertEqual(self.record(answers).returncode, 1)

    def test_missing_release_and_empty_release_have_identical_key_errors(self):
        for releases in ({}, {'v1.0.0': []}):
            self.path.write_text(json.dumps({'schema_version': 1, 'fleet': [], 'releases': releases}))
            for key, suffix in [('skills_sync', 'skills_sync'),
                                ('copier_answers', 'copier_answers.example/one')]:
                with self.subTest(releases=releases, key=key):
                    result = self.cli('--repository', 'example/one', '--require-key', key)
                    self.assertEqual(result.returncode, 1)
                    self.assertTrue(result.stderr.rstrip().endswith('missing ruling key: ' + suffix), result.stderr)
                    self.assertEqual(result.stdout, '')

    def test_narrower_recording_retires_deselected_repo_approvals(self):
        defaults = self.questions()['answers']
        for scope, selected in [({'kind': 'wave', 'wave': 2}, 'example/two'),
                                ({'kind': 'repository', 'repository': 'example/one'}, 'example/one')]:
            with self.subTest(scope=scope):
                self.path.write_text('schema_version: 1\nfleet: []\nreleases: {}\n')
                self.assertEqual(self.record(defaults).returncode, 0)
                before = json.loads(self.path.read_text())['releases']['v1.0.0']
                deselected = 'example/one' if selected == 'example/two' else 'example/two'
                old = next(e for e in before if e.get('repository') == deselected)
                answers = {**defaults, 'scope': scope, 'copier_answers': {selected: {}}}
                result = self.record(answers)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.questions()['answers'], answers)
                result = self.cli('--repository', selected, '--require-key', 'copier_answers')
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.cli('--repository', deselected, '--require-key', 'copier_answers')
                self.assertEqual(result.returncode, 1)
                self.assertIn('missing ruling key: copier_answers.' + deselected, result.stderr)
                self.assertEqual(result.stdout, '')
                result = self.cli('--repository', deselected, '--require', old['id'])
                self.assertEqual(result.returncode, 1)
                self.assertIn('superseded by', result.stderr)
                entries = json.loads(self.path.read_text())['releases']['v1.0.0']
                self.assertEqual(entries[:len(before)], before)
                scope_entry = next(e for e in entries[len(before):] if json.loads(e['ruling'])['key'] == 'scope')
                self.assertIn(old['id'], scope_entry['supersedes'])
                # Returning to the fleet creates fresh approval, never revives old IDs.
                result = self.record(defaults)
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.cli('--repository', deselected, '--require-key', 'copier_answers')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(json.loads(result.stdout)['decisions'][0]['id'], old['id'])
                self.assertEqual(self.cli('--repository', deselected, '--require', old['id']).returncode, 1)

    def test_scope_selection_and_invalid_answers_do_not_write(self):
        answers = self.questions()['answers']
        answers['scope'] = {'kind': 'wave', 'wave': 2}
        answers['copier_answers'] = {'example/two': {'project_name': 'Wave two'}}
        result = self.record(answers)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.questions()['answers'], answers)
        before = self.path.read_bytes()
        for key, value in [('scope', {'kind': 'wave', 'wave': 7}),
                           ('target_release', 'v-other'), ('skills_sync', 'per-lane'),
                           ('guarded_rollback', 'yes'), ('legacy_baseline', 1),
                           ('reconcile_classes', ['human-only']), ('review_exclusions', 'all'),
                           ('model_rulings', []), ('copier_answers', {'example/two': {'_commit': 'x'}}),
                           ('copier_answers', {'other/repo': {}})]:
            with self.subTest(key=key, value=value):
                invalid = {**answers, key: value}
                result = self.record(invalid)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(self.path.read_bytes(), before)

    def test_other_releases_preserved_and_approval_required(self):
        answers = self.questions()['answers']
        data = {'schema_version': 1, 'fleet': [], 'releases': {'v-previous': []}}
        self.path.write_text(json.dumps(data))
        self.assertEqual(self.record(answers).returncode, 0)
        self.assertEqual(json.loads(self.path.read_text())['releases']['v-previous'], [])
        result = self.cli('--record-answers', str(self.answers_file), '--inventory', str(self.inventory))
        self.assertEqual(result.returncode, 2)
        self.assertIn('--approved-by', result.stderr)

    def test_inventory_duplicates_and_missing_inputs_fail_closed(self):
        before = self.path.read_bytes()
        for rows in ([], [{'repository': 'bad-name', 'wave': 1}],
                     [{'repository': 'example/one', 'wave': True}],
                     [{'repository': 'example/one', 'wave': 1},
                      {'repository': 'EXAMPLE/one', 'wave': 2}]):
            with self.subTest(rows=rows):
                self.inventory.write_text(json.dumps({'repositories': rows}))
                result = self.cli('--questions', '--inventory', str(self.inventory))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')
                self.assertEqual(self.path.read_bytes(), before)


class BriefContractTest(unittest.TestCase):
    def test_placeholder_catalog_and_required_routing(self):
        brief = (ASSETS / 'fleet-lane-brief.md').read_text()
        reference = (ASSETS.parent / 'references/fleet-decisions.md').read_text()
        placeholders = set(re.findall(r'\{\{([a-z0-9_-]+)\}\}', brief))
        catalog = set(re.findall(r'^\| `([a-z0-9_-]+)` \|', reference, re.MULTILINE))
        self.assertEqual(placeholders, catalog - {'id', 'scope', 'ruling', 'approved_by',
                                                   'approved_on', 'supersedes'})
        self.assertTrue({'security-surfaces', 'question-file', 'decision-ids', 'decision-citations',
                         'decisions-commit', 'decisions-sha256', 'orchestrate-contract'} <= placeholders)
        rendered = re.sub(r'\{\{([a-z0-9_-]+)\}\}', lambda m: f'fixture-{m[1]}', brief)
        self.assertNotIn('{{', rendered)
        flat = ' '.join(brief.split())
        for phrase in ('all questions only to', 'Never ask in an interactive prompt',
                       'only the setup its own tasks need', 'Release-approved security surfaces',
                       'exact missing key', 'Only the parent obtains maintainer rulings',
                       'Draft PR publication is a phase transition', 'parent continues into integrate',
                       'never run `confirm-answers.sh --confirm` yourself', 'never rebuild them'):
            self.assertIn(phrase, flat)
        self.assertIn('fleet-decisions.py', (ASSETS.parent / 'SKILL.md').read_text())


if __name__ == '__main__':
    unittest.main()
