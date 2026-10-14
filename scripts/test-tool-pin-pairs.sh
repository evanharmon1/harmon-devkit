#!/usr/bin/env bash
# test-tool-pin-pairs.sh — a tool's version pin and its checksum pins move
# together, or the bump is dead on arrival.
#
# A raw release download is verified against a hard-coded per-architecture
# hash (`shfmt_sha256=…`). Bump the `SHFMT_VERSION=` line without the hashes
# and CI downloads the new binary, checks it against the OLD release's hash,
# and fails closed. Renovate keeps them together through a
# `github-release-attachments` annotation on each hash line; this guard is the
# fast local check that it (or a hand edit) actually did.
#
# Pairs are declared, never inferred: a trailing `# pin-pair: <tool>` marks
# every member line — exactly one `*_VERSION=` line and one or more
# `*_sha256=` lines per tool per file:
#
#     SHFMT_VERSION=3.14.1 # pin-pair: shfmt
#     # renovate: datasource=github-release-attachments depName=mvdan/sh digestVersion=v3.14.1
#     shfmt_sha256=76e7… # pin-pair: shfmt
#
# Two checks, both on tracked files under `.github/` (either layer):
#   1. static  — every hash member sits directly under its Renovate
#                annotation, and that annotation's tag is the version line's
#                value (with or without a leading `v`);
#   2. drift   — against the merge-base, keyed by the `case` branch (the
#                architecture) each hash sits in: no branch that had a hash
#                loses it, and when a `*_VERSION` value differs from the
#                merge-base, every branch's hash differs too. A tag bumped
#                without its hash is what Renovate leaves when it cannot find
#                the release asset.
# The drift check needs a merge-base. On a pull request (GITHUB_BASE_REF set)
# a missing one fails the guard — the checkout needs `fetch-depth: 0` — because
# the action's own `sha256sum -c` is skipped whenever the runner already has
# the pinned version (GitHub-hosted images ship a current yq). Elsewhere (a
# local clone with no remote, a push build) it is skipped with a notice.
#
# Base ref: PIN_PAIRS_BASE if set; on a pull request exactly
# origin/$GITHUB_BASE_REF (never a fallback — a wrong base would hide a stale
# hash); otherwise the first of origin/HEAD, origin/main, origin/master.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ -n "${PIN_PAIRS_BASE:-}" ]; then
    candidates=("$PIN_PAIRS_BASE")
elif [ -n "${GITHUB_BASE_REF:-}" ]; then
    candidates=("origin/${GITHUB_BASE_REF}")
else
    candidates=(origin/HEAD origin/main origin/master)
fi
base_ref=
for candidate in "${candidates[@]}"; do
    if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
        base_ref="$candidate"
        break
    fi
done
if [ -n "${PIN_PAIRS_BASE:-}" ] && [ "$base_ref" != "$PIN_PAIRS_BASE" ]; then
    echo "pin-pairs: PIN_PAIRS_BASE=${PIN_PAIRS_BASE} does not resolve to a commit" >&2
    exit 1
fi
merge_base=
if [ -n "$base_ref" ]; then
    merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null || true)"
fi
if [ -z "$merge_base" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    echo "pin-pairs: no merge-base with ${base_ref:-origin/${GITHUB_BASE_REF}} on a pull request, so a version bump that left its checksum behind cannot be detected — check out with fetch-depth: 0" >&2
    exit 1
fi

# git grep exits 1 for "no match" and 2+ for a real failure; only the former
# may read as "nothing to check".
rc=0
listing="$(git grep -l -F '# pin-pair: ' -- '.github/**' '*/.github/**')" || rc=$?
if [ "$rc" -gt 1 ]; then
    echo "pin-pairs: git grep failed (exit ${rc})" >&2
    exit 1
fi
files=()
while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
done <<<"$listing"

if [ "${#files[@]}" -eq 0 ]; then
    echo "pin-pairs OK: no '# pin-pair:' markers under .github/"
    exit 0
fi

python3 - "$base_ref" "$merge_base" "${files[@]}" <<'PY'
import re
import subprocess
import sys

base_ref, merge_base, files = sys.argv[1], sys.argv[2], sys.argv[3:]

MEMBER = re.compile(
    r"^\s*(?P<var>[A-Za-z_][A-Za-z0-9_]*)=(?P<val>\S+)\s+# pin-pair: (?P<tool>[A-Za-z0-9._-]+)\s*$"
)
MARKER = re.compile(r"# pin-pair:")
ANNOTATION = re.compile(
    r"^\s*# renovate: datasource=github-release-attachments depName=(?P<dep>\S+) digestVersion=(?P<tag>\S+)\s*$"
)
VERSION_ANNOTATION = re.compile(r"^\s*# renovate: datasource=\S+ depName=(?P<dep>\S+)")
# A shell `case` pattern line such as `X64|x86_64)` names the architecture
# branch the hashes below it belong to.
CASE_LABEL = re.compile(r"^\s*(?P<label>[^\s#()][^()]*)\)\s*$")


def parse(path, text, errors):
    """{tool: {"version": (line, var, val, dep) | None, "hashes": [(line, var, val, dep, tag, branch)]}}"""
    pairs = {}
    lines = text.splitlines()
    branch = ""
    for i, line in enumerate(lines, 1):
        label = CASE_LABEL.match(line)
        if label:
            branch = label["label"].strip()
        elif line.strip() == "esac":
            branch = ""
        # A comment-only line may talk about the marker; only code carries one.
        if not MARKER.search(line) or line.lstrip().startswith("#"):
            continue
        m = MEMBER.match(line)
        if not m:
            errors.append(f"{path}:{i}: '# pin-pair:' marker on a line that is not `NAME=value # pin-pair: <tool>`")
            continue
        tool, var, val = m["tool"], m["var"], m["val"]
        entry = pairs.setdefault(tool, {"version": None, "hashes": []})
        if var.endswith("_VERSION"):
            if entry["version"]:
                errors.append(f"{path}:{i}: pin-pair '{tool}' has a second version line (first at line {entry['version'][0]})")
                continue
            ann = VERSION_ANNOTATION.match(lines[i - 2]) if i >= 2 else None
            if not ann:
                errors.append(
                    f"{path}:{i}: pin-pair '{tool}' version {var} is not directly under a "
                    "`# renovate: datasource=… depName=<owner/repo>` annotation, so Renovate would "
                    "move its hashes but never the version"
                )
            entry["version"] = (i, var, val, ann["dep"] if ann else None)
        elif var.lower().endswith("_sha256"):
            # Exactly the name grammar the renovate.json checksum manager
            # extracts (`[a-z0-9_]+_sha256`); anything else is never updated.
            if not re.fullmatch(r"[a-z0-9_]+_sha256", var):
                errors.append(
                    f"{path}:{i}: pin-pair '{tool}' hash {var} must be lowercase `[a-z0-9_]+_sha256` "
                    "— the Renovate checksum manager extracts nothing else"
                )
            if not re.fullmatch(r"[0-9a-f]{64}", val):
                errors.append(f"{path}:{i}: pin-pair '{tool}' hash {var} is not 64 lowercase hex digits")
            ann = ANNOTATION.match(lines[i - 2]) if i >= 2 else None
            if not ann:
                errors.append(
                    f"{path}:{i}: pin-pair '{tool}' hash {var} is not directly under a "
                    "`# renovate: datasource=github-release-attachments depName=<owner/repo> digestVersion=<tag>` "
                    "annotation, so Renovate will never update it"
                )
            dup = next((h for h in entry["hashes"] if (h[1], h[5]) == (var, branch)), None)
            if dup:
                errors.append(
                    f"{path}:{i}: pin-pair '{tool}' assigns {var} twice in the same branch "
                    f"({branch or 'outside a case'}; first at line {dup[0]})"
                )
            entry["hashes"].append((i, var, val, ann["dep"] if ann else None, ann["tag"] if ann else None, branch))
        else:
            errors.append(f"{path}:{i}: pin-pair '{tool}' member {var} is neither a *_VERSION nor a *_sha256 line")
    return pairs


errors = []
checked = 0
for path in files:
    with open(path, encoding="utf-8", errors="replace") as fh:
        head = parse(path, fh.read(), errors)
    base = None
    if merge_base:
        shown = subprocess.run(
            ["git", "show", f"{merge_base}:{path}"], capture_output=True, text=True
        )
        if shown.returncode == 0:
            base = parse(path, shown.stdout, [])
    for tool, entry in sorted(head.items()):
        checked += 1
        if not entry["version"]:
            errors.append(f"{path}: pin-pair '{tool}' has hash lines but no `*_VERSION=… # pin-pair: {tool}` line")
            continue
        if not entry["hashes"]:
            errors.append(f"{path}:{entry['version'][0]}: pin-pair '{tool}' has a version line but no `*_sha256=… # pin-pair: {tool}` lines")
            continue
        vline, vvar, version, vdep = entry["version"]
        for line, var, _, dep, tag, _branch in entry["hashes"]:
            if dep is not None and vdep is not None and dep != vdep:
                errors.append(
                    f"{path}:{line}: pin-pair '{tool}': {var} is annotated for {dep} but {vvar} "
                    f"(line {vline}) tracks {vdep} — Renovate would compute this hash from the wrong project"
                )
            if tag is not None and tag.removeprefix("v") != version.removeprefix("v"):
                errors.append(
                    f"{path}:{line}: pin-pair '{tool}': {var} is annotated for {tag} but {vvar} is {version} "
                    f"(line {vline}) — the hash belongs to a different release.\n"
                    f"    fix: set digestVersion to the release tag of {version} and the hash to that release asset's sha256:\n"
                    f"         curl -fsSL https://github.com/{dep}/releases/download/<tag>/<asset> | sha256sum\n"
                    f"         (<asset> is the file this step downloads for that architecture)"
                )
        old = (base or {}).get(tool)
        if not old or not old["version"]:
            continue
        # Keyed by (variable, case branch): an architecture that had a hash at
        # the merge-base must still have one, whether or not the version moved.
        current = {(h[1], h[5]) for h in entry["hashes"]}
        for h in old["hashes"]:
            if (h[1], h[5]) not in current:
                errors.append(
                    f"{path}: pin-pair '{tool}': {h[1]} for branch `{h[5] or 'outside a case'}` existed at "
                    f"{base_ref} and is gone — that architecture lost its checksum"
                )
        if old["version"][2] == version:
            continue
        old_hashes = {h[2] for h in old["hashes"]}
        stale = [h for h in entry["hashes"] if h[2] in old_hashes]
        if stale:
            dep = next((h[3] for h in entry["hashes"] if h[3]), "<owner/repo>")
            lines_ = ", ".join(str(h[0]) for h in stale)
            errors.append(
                f"{path}: pin-pair '{tool}': {vvar} changed {old['version'][2]} -> {version} since {base_ref} "
                f"but these paired hash lines did not: {lines_}.\n"
                f"    fix: on a Renovate PR, retry it from the Dependency Dashboard so Renovate recomputes the hashes;\n"
                f"         by hand, replace each hash with the sha256 of that architecture's asset for the new release:\n"
                f"         curl -fsSL https://github.com/{dep}/releases/download/<tag>/<asset> | sha256sum\n"
                f"         (<asset> is the file this step downloads for that architecture)"
            )

for e in errors:
    print(f"FAIL: {e}", file=sys.stderr)
if errors:
    sys.exit(1)
drift = f"drift checked against {base_ref}" if merge_base else "drift check skipped: no merge-base (shallow checkout or no remote)"
print(f"pin-pairs OK: {checked} pair(s) in {len(files)} file(s); {drift}")
PY
