#!/usr/bin/env python3
"""Offline behavioral tests for fleet decisions and the fleet brief contract."""

import copy
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ASSETS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fleet_decisions', ASSETS / 'fleet-decisions.py')
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)


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
        for key, value in [('id', 'lowercase'), ('ruling', '  '), ('approved_by', ''),
                           ('approved_on', '2026-02-30'), ('scope', 'release'),
                           ('repository', 'example/repo')]:
            item = copy.deepcopy(self.data)
            item['fleet'][0][key] = value
            cases.append(item)
        for value in ('bad-name', '', 'owner/repo/extra'):
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


class BriefContractTest(unittest.TestCase):
    def test_placeholder_catalog_and_required_routing(self):
        brief = (ASSETS / 'fleet-lane-brief.md').read_text()
        reference = (ASSETS.parent / 'references/fleet-decisions.md').read_text()
        placeholders = set(re.findall(r'\{\{([a-z0-9_-]+)\}\}', brief))
        catalog = set(re.findall(r'^\| `([a-z0-9_-]+)` \|', reference, re.MULTILINE))
        self.assertEqual(placeholders, catalog - {'id', 'scope', 'ruling', 'approved_by', 'approved_on'})
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
