#!/usr/bin/env bash
# Check the documented label-write surface without making GitHub writes.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
from pathlib import Path
from collections import Counter
import re
import sys

root = Path(sys.argv[1])
table_path = Path('docs/dev-loop/label-lifecycle.md')
asset_root = Path('ai/skills/universal')
skills = ('claim', 'orchestrate', 'integrate', 'track-work')
# Also catches flags assembled into argv arrays before gh is invoked. Quoted
# flag strings in argument parsers are data rather than executable options.
flag = re.compile(r'''(?<![\w-])([\'"]?)(--(?:add|remove)-label)\1(?:\s+|=)("[^"\n]*"|'[^'\n]*'|[^\s;)]+)''')
row = re.compile(r'^\| `([^`]+/assets/[^`]+)` \| `(--(?:add|remove)-label)` \| `([^`]+)` \| (.+) \|$', re.M)
label_name = re.compile(r'[a-z0-9]+(?:[-:][a-z0-9]+)*(?::\*)?\Z')


def check(files, table):
    errors = []
    inventory = {}
    for path, operation, operand, vocabulary in row.findall(table):
        key = (path, operation, operand)
        if key in inventory:
            errors.append(f'duplicate inventory site: {key}')
        names = re.findall(r'`([^`]+)`', vocabulary)
        if not names or any(not label_name.fullmatch(name) for name in names):
            errors.append(f'non-lowercase or invalid inventory vocabulary: {vocabulary}')
        inventory[key] = names
    found = Counter()
    for path, source in files.items():
        # Fold shell continuations; retain line numbers for useful diagnostics.
        source = re.sub(r'\\\n', ' ', source)
        for number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            for match in flag.finditer(line):
                _, operation, operand = match.groups()
                key = (path, operation, operand)
                found[key] += 1
                if key not in inventory:
                    errors.append(f'{path}:{number}: undocumented write: {operation} {operand}')
                literal = operand.strip('"\'')
                if '$' not in literal:
                    for name in literal.split(','):
                        if not label_name.fullmatch(name):
                            errors.append(f'{path}:{number}: invalid or non-lowercase label: {name}')
                        elif key in inventory and name not in inventory[key]:
                            errors.append(f'{path}:{number}: label absent from table: {name}')
            # There are no approved REST label writes today. Refuse any new
            # label endpoint (including a variable URL) in a gh api command,
            # except an explicit GET. Unknown dynamic routes are also refused
            # when the API command supplies label fields. No REST allowlist is
            # hidden in this test: adding one requires a documented table site.
            if re.search(r'\bgh\s+api\b', line):
                label_route = re.search(r'/labels(?:\b|/)|(?:-f|--field|--raw-field)\s+[\'\"]?labels?(?:\[\])?=', line)
                get = re.search(r'(?:--method(?:=|\s+)|-X\s+)GET\b', line)
                if label_route and not get:
                    errors.append(f'{path}:{number}: undocumented REST label call')
    for key in inventory.keys() - found.keys():
        errors.append(f'inventory site no longer exists: {key}')
    for name in ('claim:*', 'slated', 'parked', 'merge-ready', 'needs-review', 'blocked'):
        if not re.search(r'^\| `' + re.escape(name) + r'`', table, re.M):
            errors.append(f'missing transition row: {name}')
    return errors, found


files = {}
for skill in skills:
    for path in sorted((root / asset_root / skill / 'assets').rglob('*')):
        if path.is_file():
            try:
                files[str(path.relative_to(root / asset_root))] = path.read_text()
            except UnicodeDecodeError:
                continue

table = (root / table_path).read_text()
errors, writes = check(files, table)
if errors:
    sys.exit('\n'.join(errors))
for (path, operation, operand), count in sorted(writes.items()):
    print(f'{path}: {operation} {operand} ({count} site(s))')

# Negative probes run entirely in memory, avoiding GitHub and disposable repo
# copies. Each probe changes one realistic input to the same checker.
def rejects(name, changed_files, changed_table=table):
    failures, _ = check(changed_files, changed_table)
    if not failures:
        sys.exit(f'negative probe accepted: {name}')


for name, command in (
    ('unknown label', 'gh issue edit 1 --repo owner/repo --add-label surprise'),
    ('uppercase label', 'gh pr edit 1 --repo owner/repo --add-label Needs-Review'),
    ('dynamic label', 'gh issue edit 1 --repo owner/repo --remove-label "$unregistered"'),
    ('argv array', 'args+=(--add-label blocked)'),
    ('quoted argv flag', 'args+=("--add-label" blocked)'),
    ('REST POST', 'gh api repos/owner/repo/issues/1/labels -X POST -f labels[]=blocked'),
    ('REST DELETE', 'gh api -X DELETE repos/owner/repo/issues/1/labels/blocked'),
    ('REST variable route', 'gh api "$route" --method PATCH -f labels[]=blocked'),
):
    rejects(name, {**files, 'integrate/assets/probe.sh': command})
rejects('uppercase table vocabulary', files, table.replace('| `needs-triage` |', '| `Needs-Triage` |'))
missing = dict(files)
missing['track-work/assets/clear-needs-review.sh'] = ''
rejects('stale inventory', missing)

url = 'docs/dev-loop/label-lifecycle.md'
for skill in skills:
    text = (root / asset_root / skill / 'SKILL.md').read_text()
    if url not in text:
        sys.exit(f'{skill} does not link the canonical table')
for path, target in (
    ('docs/glossary.md', 'dev-loop/label-lifecycle.md'),
    ('docs/project-management.md', 'dev-loop/label-lifecycle.md'),
    ('docs/decisions/2026-10-23-pr-lifecycle-handoff-check-and-merge-queue.md', '../dev-loop/label-lifecycle.md'),
):
    if target not in (root / path).read_text():
        sys.exit(f'{path} does not link the canonical table')
queue = (root / 'docs/project-management.md').read_text().split('### The Agent queue\n', 1)[1].split('\n### ', 1)[0]
for name in ('claim:*', 'parked', 'merge-ready', 'needs-review', 'blocked'):
    if f'`{name}`' not in queue:
        sys.exit(f'Agent queue omission: {name}')
if 'Working is not a label.' not in table or '**or an open delivery PR**' not in table:
    sys.exit('missing Working/in-flight contract')
print(f'label lifecycle: {sum(writes.values())} executable label sites; negative probes passed')
PY
