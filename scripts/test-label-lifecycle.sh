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
skills = ('claim', 'orchestrate', 'integrate', 'track-work', 'dev-flow-support')
# Also catches flags assembled into argv arrays before gh is invoked. Quoted
# flag strings in argument parsers are data rather than executable options.
flag = re.compile(r'''(?<![\w-])([\'"]?)(--(?:(?:add|remove)-label|label)|-l)\1(?:\s+|=|(?<=-l)(?=[^\s]))("[^"\n]*"|'[^'\n]*'|[^\s;)]+)''')
row = re.compile(r'^\| `([^`]+/assets/[^`]+)` \| `(--(?:(?:add|remove)-label|label)|-l)` \| `([^`]+)` \| (.+) \|$', re.M)
label_name = re.compile(r'[a-z0-9]+(?:[-:][a-z0-9]+)*(?::\*)?\Z')


def check(files, table):
    errors = []
    inventory = {}
    expected = {}
    for path, operation, operand, vocabulary in row.findall(table):
        key = (path, operation, operand)
        if key in inventory:
            errors.append(f'duplicate inventory site: {key}')
        names = re.findall(r'`([^`]+)`', vocabulary)
        filing_metadata = vocabulary == 'Caller-supplied lowercase filing metadata (validated by the issue-metadata preflight).'
        if (not names and not filing_metadata) or any(not label_name.fullmatch(name) for name in names):
            errors.append(f'non-lowercase or invalid inventory vocabulary: {vocabulary}')
        inventory[key] = names
        expected[key] = 2 if vocabulary.endswith("(2 sites)") else 1
    found = Counter()
    for path, source in files.items():
        # Scan complete shell statements, including parenthesized argv arrays.
        # A label flag is a candidate even before its gh invocation: the
        # inventory is the authority for both direct and assembled writes.
        source = re.sub(r"\\\n", " ", source)
        source = re.sub(r"(?m)^\s*#.*$", "", source)
        # Collect label arguments from the whole file. --add/remove-label
        # are always suspicious; --label/-l are suspicious in a gh command
        # or a gh argv array, including subsequent array appends.
        create_flags = set()
        patterns = [r"\bgh\s+(?:issue|pr)\s+(?:create|edit)\b[^\n;]*"]
        patterns.append(r"\b\w+\+?=\([^()\n]*(?:\n[^()]*)?\)")
        for pattern in patterns:
            for chunk in re.finditer(pattern, source):
                for match in flag.finditer(chunk.group()):
                    create_flags.add(chunk.start() + match.start())
        helper_site = 'metadata+=(--label "$label")'
        helper_path = 'track-work/assets/file-review-finding.sh'
        helper_positions = [m.start() for m in re.finditer(re.escape(helper_site), source)] if path == helper_path else []
        if path == helper_path and (len(helper_positions) != 1 or f'`{helper_site}`' not in table):
            errors.append(f'{path}: missing or duplicated inventoried metadata helper')
        for match in flag.finditer(source):
            if any(pos <= match.start() < pos + len(helper_site) for pos in helper_positions):
                continue
            if source[match.end():match.end()+1] == ',':
                continue
            _, operation, operand = match.groups()
            if operation in ('--label', '-l') and match.start() not in create_flags:
                continue
            key = (path, operation, operand)
            found[key] += 1
            number = source.count('\n', 0, match.start()) + 1
            if key not in inventory:
                errors.append(f'{path}:{number}: undocumented write: {operation} {operand}')
            literal = operand.strip('"\'')
            if '$' not in literal:
                for name in literal.split(','):
                    if not label_name.fullmatch(name):
                        errors.append(f'{path}:{number}: invalid or non-lowercase label: {name}')
                    elif key in inventory and name not in inventory[key]:
                        errors.append(f'{path}:{number}: label absent from table: {name}')
        # Node argv arrays use commas between quoted arguments.
        for match in re.finditer(r"github\(\[([^]]*)\]", source, re.S):
            for operation, operand in re.findall(r"['\"](--(?:add|remove)-label)['\"]\s*,\s*['\"]([^'\"]+)['\"]", match.group(1)):
                key = (path, operation, operand)
                found[key] += 1
                if key not in inventory or operand not in inventory[key]:
                    errors.append(f'{path}: undocumented Node label write: {operation} {operand}')
        # REST statements are inspected as a unit; the final explicit method
        # wins, just as gh does. Fields imply POST when no method is supplied.
        api_calls = list(re.finditer(r"\bgh\s+api\b[^\n;]*", source))
        # Arrays can place the route, fields and method on separate lines.
        api_calls.extend(match for match in re.finditer(r"\b\w+\+?=\([^()]*\)", source)
                         if re.search(r"\bgh\s+api\b", match.group()))
        api_arrays = set(re.findall(r"\b(\w+)=\(\s*gh\s+api\b", source))
        assembled = []
        for name in api_arrays:
            parts = list(re.finditer(r"\b" + re.escape(name) + r"\+?=\([^()]*\)", source))
            if parts:
                assembled.append((parts[0].start(), " ".join(part.group() for part in parts)))
        for offset, text in [(call.start(), call.group()) for call in api_calls] + assembled:
            route = re.search(r"/labels(?:\b|/)", text)
            fields = re.search(r"(?:-[fF]|--field|--raw-field)(?:\s+|=)?['\"]?labels?(?:\[[^]]*\])?=", text)
            body = re.search(r"--input(?:=|\s+)", text)
            methods = re.findall(r"(?:--method(?:=|\s+)|-X(?:=|\s*))([A-Za-z]+)", text)
            method = methods[-1].upper() if methods else ('POST' if fields or body else 'GET')
            if (route or fields or body) and method != 'GET':
                errors.append(f'{path}:{source.count(chr(10), 0, offset) + 1}: undocumented REST label call')
        if re.search(r"\b(?:addLabelsToLabelable|removeLabelsFromLabelable)\b", source):
            errors.append(f'{path}: undocumented GraphQL label mutation')
    for key, count in expected.items():
        if found[key] != count:
            errors.append(f'inventory site count mismatch: {key}: expected {count}, found {found[key]}')
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
    ('multiline create array', 'create=(gh issue create\n --label blocked\n)'),
    ('separate argv array', 'args=(--label blocked)\ngh issue create "${args[@]}"'),
    ('appended create array', 'create=(gh issue create)\ncreate+=(--label blocked)'),
    ('appended REST array', 'args=(gh api)\nargs+=(-f labels[0]=blocked)'),
    ('multiline REST array', 'args=(gh api\n repos/owner/repo/issues/1/labels\n -X POST\n)'),
    ('indexed REST field', 'gh api "$route" -f labels[0]=blocked'),
    ('GraphQL mutation', 'gh api graphql -f query="mutation { addLabelsToLabelable(input: {}) { clientMutationId } }"'),
    ('overridden GET', 'gh api repos/owner/repo/issues/1/labels -X GET -X PATCH'),
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
changed = dict(files)
path = 'track-work/assets/file-review-finding.sh'
changed[path] = changed[path].replace('create+=(--label "$label")', 'create+=(--title "$label")')
rejects('missing create label with helper retained', changed, diagnostic='inventory site count mismatch')
changed = dict(files)
changed[path] += '\ncreate+=(--label "$label")\n'
rejects('additional inventoried operand', changed, diagnostic='inventory site count mismatch')
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
for skill in (name for name in skills if name != 'dev-flow-support'):
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
