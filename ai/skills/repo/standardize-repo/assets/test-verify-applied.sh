#!/usr/bin/env bash
# Marker-scan regressions, isolated from unrelated post-apply gates.
set -euo pipefail
assets="$(cd "$(dirname "$0")" && pwd)"
python3 -B - "$assets/verify-applied.sh" <<'PY_TEST'
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

source = Path(sys.argv.pop()).read_text()
scan = source.split('# ── 4. No unrendered template markers', 1)[1]
scan = scan.split('# ── 5. No secrets', 1)[0]
scan = '# ── 4. No unrendered template markers' + scan


class Markers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_scan(self, expected, git=False):
        if git:
            subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        result = subprocess.run(['bash', '-c', 'set -euo pipefail\nfail=0\n'
                                 'err() { echo "FAIL: $*" >&2; fail=1; }\n'
                                 + scan + '\nexit "$fail"\n'],
                                cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, int(bool(expected)), result.stderr)
        for name in expected:
            self.assertIn('    ' + name + '\n', result.stderr)
        if not expected:
            self.assertEqual(result.stderr, '')
        return result

    def test_consumer_fixture_paths_and_generator_literals(self):
        self.write('scripts/test-agent-profile.sh', '''#!/bin/bash
profile="template/[% if devcontainer %].devcontainer[% endif %]/profile"
''')
        self.write('scripts/test-devcontainer-git-ownership.sh', '''#!/bin/bash
template_common="template/[% if devcontainer %].devcontainer[% endif %]/scripts/post-create-common.sh"
''')
        self.write('scripts/test-hooks.sh', '''#!/bin/bash
for hook in "template/.claude/hooks/[% if use_codex_review %]gate[% endif %]"; do :; done
''')
        self.write('scripts/test-label-registry.sh', '''#!/bin/bash
template_doc="template/docs/[% if project_management == 'github' %]project-management.md[% endif %].jinja"
''')
        self.write('scripts/test-sync-devkit-release.sh', '''#!/bin/bash
# Template names ([% if … %]…[% endif %]) are data here.
HELPER="$SCRIPT_DIR/[% if use_skills_sync %]sync-devkit-release.sh[% endif %]"
''')
        self.write('scripts/test-skills.sh', '''#!/bin/bash
mkdir -p "$AGG_TARGET/template/[% if include_terraform %]terraform[% endif %]"
cat <<'YAML'
  when: "{{ use_codex_review }}"
YAML
''')
        self.write('scripts/label-registry-render.mjs', '''
if (openGate !== null) lines.push('[% endif %]')
if (next !== null) lines.push(`[% if ${GATE_ANSWER[next]} %]`)
''')
        self.run_scan([], git=True)
        # The same rules apply before git init.
        import shutil
        shutil.rmtree(self.root / '.git')
        self.run_scan([])

    def test_real_leaks_in_rendered_files_even_inside_quotes(self):
        for name, text in {
            'README.md': 'Name: [[ project_name ]]\n',
            'config.yml': 'name: "{{ project_name }}"\n',
            '.github/workflows/build.yml': '[% if use_codeql %]\n',
            'scripts/install.sh': 'echo "[[ project_name ]]"\n',
            'scripts/render.mjs': 'const name = "[[ project_name ]]"\n',
            'scripts/render-apostrophe.mjs': "const label = 'can\\'t'; [% if use_codeql %] run('ok');\n",
            'scripts/render-comment-quote.mjs': "/* don't enable by default */ [% if use_codeql %] run('ok');\n",
            'scripts/render-regex-quote.mjs': "const regex = /'/; [% if use_codeql %] run('ok');\n",
            'scripts/test-unclosed.sh': 'echo "[% if use_codeql %]\n',
            'scripts/test-executable.sh': '[% if use_codex_review %]\n',
            'scripts/test-command.sh': 'echo `[[ project_name ]]`\n',
            'scripts/test-substitution.sh': 'echo "$([% if use_codeql %])"\n',
            'scripts/test-quoted-command.sh': 'echo "`[% if use_codeql %]`"\n',
            'scripts/test-nested-command.sh': 'echo "$(echo "x"; [% if use_codeql %])"\n',
            'scripts/render-comment-string.mjs': 'const value = `\n// [[ project_name ]]\n`;\n',
            'scripts/render-expression.mjs': 'const value = `${[% if use_codeql %]}`\n',
            'scripts/render-later-expression.mjs': 'const value = `[% if ${[% if use_codeql %]} %]`\n',
        }.items():
            with self.subTest(name=name):
                self.write(name, text)
                self.run_scan([name], git=True)
                (self.root / name).unlink()

    def test_quoted_fixture_does_not_hide_a_leak_on_the_same_line(self):
        name = 'scripts/test-mixed.sh'
        self.write(name, 'path="template/[% if use_codeql %]x[% endif %]"; [[ project_name ]]\n')
        self.run_scan([name])

    def test_preserves_ignores_and_handles_spaces(self):
        self.write('.gitignore', 'cache/\n')
        self.write('cache/leak.txt', '[[ project_name ]]\n')
        self.write('assets/sample.jinja', '[[ project_name ]]\n')
        self.write('assets/sample.j2', '{{ project_name }}\n')
        self.write('ai/skills/example/reference.md', '[[ project_name ]]\n')
        self.write('normal.sh', '[[ true ]]\n[[ -n "$value" ]]\n')
        self.run_scan([], git=True)
        self.write('file with spaces.yml', '[%- if use_codeql %]\n')
        self.run_scan(['file with spaces.yml'])
        # A tracked ignored file must still be scanned.
        subprocess.run(['git', 'add', '-f', 'cache/leak.txt'], cwd=self.root, check=True)
        self.run_scan(['cache/leak.txt', 'file with spaces.yml'])

    def test_non_git_dependency_exclusions(self):
        for directory in ['node_modules', '.venv', '.terraform', '.task', '.worktrees', 'dist']:
            self.write(directory + '/example.txt', '[[ project_name ]]\n')
        self.run_scan([])

    def test_binary_and_symlink_are_not_followed(self):
        (self.root / 'binary').write_bytes(b'\0[[ project_name ]]')
        (self.root / 'outside').symlink_to('/nonexistent')
        self.run_scan([])


unittest.main()
PY_TEST
