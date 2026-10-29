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
flag = re.compile(r'''(?<![\w-])([\'"]?)(--(?:(?:add|remove)-label|label)|-l)\1(?:\s+|=|(?<=-l)(?=[^\s]))("[^"\n]*"|'[^'\n]*'|[^\s;)]+)''')
row = re.compile(r'^\| `([^`]+/assets/[^`]+)` \| `(--(?:(?:add|remove)-label|label)|-l)` \| `([^`]+)` \| (.+) \|$', re.M)
label_name = re.compile(r'[a-z0-9]+(?:[-:][a-z0-9]+)*(?::\*)?\Z')


def check(files, table):
    errors = []
    inventory = {}
    for path, operation, operand, vocabulary in row.findall(table):
        key = (path, operation, operand)
        if key in inventory:
            errors.append(f'duplicate inventory site: {key}')
        names = re.findall(r'`([^`]+)`', vocabulary)
        filing_metadata = vocabulary == 'Caller-supplied lowercase filing metadata (validated by the issue-metadata preflight).'
        if (not names and not filing_metadata) or any(not label_name.fullmatch(name) for name in names):
            errors.append(f'non-lowercase or invalid inventory vocabulary: {vocabulary}')
        inventory[key] = names
    found = Counter()
    for path, source in files.items():
        # Fold shell continuations; retain line numbers for useful diagnostics.
        source = re.sub(r'\\\n', ' ', source)
        # --label/-l also occur in metadata-checker calls and parsers. Track
        # arrays initialized with gh create/edit so only executable gh argv
        # additions count, alongside direct commands.
        gh_arrays = re.findall(r'\b(\w+)=\(gh\s+(?:issue|pr)\s+(?:create|edit)\b', source)
        for number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            for match in flag.finditer(line):
                _, operation, operand = match.groups()
                if operation in ('--label', '-l'):
                    direct = re.search(r'\bgh\s+(?:issue|pr)\s+(?:create|edit)\b', line)
                    argv = any(re.search(r'\b' + re.escape(name) + r'\+?=\(', line) for name in gh_arrays)
                    if not direct and not argv:
                        continue
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
                label_route = re.search(r'/labels(?:\b|/)|(?:-[fF]|--field|--raw-field)(?:\s+|=)[\'\"]?labels?(?:\[\])?=', line)
                body_input = re.search(r'(?:--input(?:=|\s+)|-[fF](?=labels?(?:\[\])?=))', line)
                get = re.search(r'(?:--method(?:=|\s+)|-X\s+)GET\b', line)
                if (label_route or body_input) and not get:
                    errors.append(f'{path}:{number}: undocumented REST label call')
    for key in inventory.keys() - found.keys():
        errors.append(f'inventory site no longer exists: {key}')
    for name in ('claim:*', 'slated', 'parked', 'merge-ready', 'needs-review', 'blocked'):
        if not re.search(r'^\| `' + re.escape(name) + r'`', table, re.M):
            errors.append(f'missing transition row: {name}')
    # The dynamic helper write is paired only while both object callers and
    # the claim transaction's delegated cleanup remain present. Inventory the
    # delegation separately from label flags so an issue-only regression fails.
    helper = files.get('track-work/assets/clear-needs-review.sh', '')
    for kind in ('issue', 'pr'):
        if not re.search(r'^\s*clear_marker ' + kind + r' ', helper, re.M):
            errors.append(f'missing paired helper {kind} write')
    delegation = '"$cleanup_dir/clear-needs-review.sh" --repo "$repo" --issue "$issue" --branch "$recorded_branch"'
    if delegation not in files.get('claim/assets/claim-transaction.sh', '') or delegation not in table:
        errors.append('missing inventoried claim paired cleanup')
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
def rejects(name, changed_files, changed_table=table, diagnostic=None):
    failures, _ = check(changed_files, changed_table)
    if not failures or (diagnostic and not any(diagnostic in failure for failure in failures)):
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
    rejects(name, {**files, 'integrate/assets/probe.sh': command}, diagnostic='integrate/assets/probe.sh:')
# Exercise every supported spelling independently; require a diagnostic at
# the probe site so a stale inventory elsewhere cannot make a probe pass.
for subject in ('issue', 'pr'):
    for verb in ('create', 'edit'):
        options = ('--label blocked', '--label=blocked', '-l blocked', '-l=blocked', '-lblocked') if verb == 'create' else (
            '--add-label blocked', '--add-label=blocked', '--remove-label blocked', '--remove-label=blocked')
        for option in options:
            command = f'gh {subject} {verb} 1 {option}'
            rejects(command, {**files, 'integrate/assets/probe.sh': command}, diagnostic='undocumented write:')
for option in ('-f labels[]=blocked', '-F labels[]=blocked',
               '--field labels[]=blocked', '--field=labels[]=blocked',
               '--raw-field labels[]=blocked', '--raw-field=labels[]=blocked',
               '-flabels[]=blocked', '-Flabels[]=blocked',
               '--input labels.json', '--input=labels.json'):
    command = f'gh api "$route" {option}'
    rejects(command, {**files, 'integrate/assets/probe.sh': command}, diagnostic='undocumented REST label call')
rejects('uppercase table vocabulary', files, table.replace('| `needs-triage` |', '| `Needs-Triage` |'))
missing = dict(files)
missing['track-work/assets/clear-needs-review.sh'] = ''
rejects('stale inventory', missing)
for kind in ('issue', 'pr'):
    changed = dict(files)
    path = 'track-work/assets/clear-needs-review.sh'
    changed[path] = changed[path].replace(f'clear_marker {kind} ', f'retired_marker {kind} ')
    rejects(f'missing paired {kind} write', changed, diagnostic=f'missing paired helper {kind} write')
changed = dict(files)
path = 'claim/assets/claim-transaction.sh'
changed[path] = changed[path].replace('"$cleanup_dir/clear-needs-review.sh"', '"$cleanup_dir/retired-helper.sh"')
rejects('missing claim paired cleanup', changed, diagnostic='missing inventoried claim paired cleanup')

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
