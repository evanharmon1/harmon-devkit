#!/usr/bin/env bash
# Offline producer/binding regressions and shared runner fixture construction.
set -euo pipefail

# Turn the runner tests' expected render snapshots into actual tagged Copier
# templates, then replace the hand-built bundle with producer output. This is
# test data setup, never a signer or a production verification substitute.
render_bundle_fixture() {
    local bundle="$1" target="$2" base="$3" head="$4" release="$5"
    local source="${bundle}-template" assets side tag
    assets="${repo}/ai/skills/repo/standardize-repo/assets"
    rm -rf "$source"
    mkdir -p "$source/template"
    git init -q "$source"
    git -C "$source" config user.name Fixture
    git -C "$source" config user.email fixture@example.invalid
    printf '_subdirectory: template\n' >"$source/copier.yml"
    if [ "${RENDER_BUNDLE_TEST_GLOBS:-}" = 1 ]; then
        cat >>"$source/copier.yml" <<'YAML'
_envops:
  variable_start_string: "[["
  variable_end_string: "]]"
_skip_if_exists:
  - src/repo-owned.txt
  - "*.code-workspace"
  - /root-owned/*.txt
  - docs/[[ undecidable ]].txt
YAML
    else
        printf '_skip_if_exists: [src/repo-owned.txt]\n' >>"$source/copier.yml"
    fi
    for side in previous current; do
        rm -rf "$source/template"
        mkdir -p "$source/template"
        cp -R "$bundle/$side/." "$source/template/"
        : >"$source/template/.fixture"
        if [ "${RENDER_BUNDLE_TEST_GLOBS:-}" = 1 ]; then
            printf '[[ range(65536) | random ]]-[[ range(65536) | random ]]-[[ range(65536) | random ]]\n' \
                >"$source/template/fixture.code-workspace.jinja"
        fi
        rm -f "$source/template/.copier-answers.yml"
        git -C "$source" add -A
        git -C "$source" commit -qm "test: $side template" --allow-empty
        if [ "$side" = previous ]; then tag=v1.0.0; else tag="$release"; fi
        git -C "$source" tag "$tag"
    done
    export HARMON_INIT="$source"
    # Retain additive operator protection while the producer initializes empty
    # lists by default.
    cp "$bundle/conflict-resolutions.nul" "${bundle}-conflicts.nul"
    rm -rf "$bundle"
    bash "$assets/render-bundle.sh" --previous-release v1.0.0 --release "$release" \
        --base "$base" --head "$head" --output "$bundle" "$target"
    cp "${bundle}-conflicts.nul" "$bundle/conflict-resolutions.nul"
}

if [ "${1:-}" = --fixture-functions ]; then
    return 0
fi

repo="$(git rev-parse --show-toplevel)"
assets="$repo/ai/skills/repo/standardize-repo/assets"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { # shell-robustness: ok — this reporter always terminates the test process
    echo "FAIL: $*" >&2
    exit 1
}
work="$tmp/repo"
bundle="$tmp/bundle"
mkdir -p "$work/src" "$bundle/previous/src" "$bundle/current/src"
git init -q "$work"
git -C "$work" config user.name Fixture
git -C "$work" config user.email fixture@example.invalid
printf '_commit: v1.0.0\n' >"$work/.copier-answers.yml"
for name in generated customized repo-owned nested.code-workspace; do
    printf 'old template\n' >"$bundle/previous/src/$name.txt"
    printf 'new template\n' >"$bundle/current/src/$name.txt"
    cp "$bundle/previous/src/$name.txt" "$work/src/$name.txt"
done
mv "$work/src/nested.code-workspace.txt" "$work/src/nested.code-workspace"
for side in previous current; do
    mv "$bundle/$side/src/nested.code-workspace.txt" "$bundle/$side/src/nested.code-workspace"
done
for path in root-owned/owned.txt nested/root-owned/generated.txt docs/owned.txt; do
    mkdir -p "$work/$(dirname "$path")"
    for side in previous current; do
        mkdir -p "$bundle/$side/$(dirname "$path")"
        printf '%s template\n' "$side" >"$bundle/$side/$path"
    done
    cp "$bundle/previous/$path" "$work/$path"
done
printf 'local old\n' >"$work/src/customized.txt"
git -C "$work" add -A
git -C "$work" commit -qm 'test: baseline'
base="$(git -C "$work" rev-parse HEAD)"
printf '_commit: v2.0.0\n' >"$work/.copier-answers.yml"
cp "$bundle/current/src/generated.txt" "$work/src/generated.txt"
cp "$bundle/current/src/repo-owned.txt" "$work/src/repo-owned.txt"
cp "$bundle/current/src/nested.code-workspace" "$work/src/nested.code-workspace"
for path in root-owned/owned.txt nested/root-owned/generated.txt docs/owned.txt; do
    cp "$bundle/current/$path" "$work/$path"
done
printf 'local new\n' >"$work/src/customized.txt"
git -C "$work" add -A
git -C "$work" commit -qm 'test: update'
head="$(git -C "$work" rev-parse HEAD)"
: >"$bundle/conflict-resolutions.nul"
RENDER_BUNDLE_TEST_GLOBS=1 render_bundle_fixture "$bundle" "$work" "$base" "$head" v2.0.0
exclusions() {
    bash "$assets/diff-template.sh" --review-exclusions --release v2.0.0 \
        --base "$base" --head "$head" --frozen-render "$bundle" "$work"
}
printf 'nested/root-owned/generated.txt\0src/generated.txt\0' >"$tmp/expected"
exclusions >"$tmp/actual"
cmp "$tmp/expected" "$tmp/actual" || fail 'customized or derived repo-owned path was excluded'
echo 'PASS: _envops/glob patterns retain owned files and exclude pristine template content'
printf 'different random workspace value\n' >"$bundle/current/fixture.code-workspace"
exclusions >"$tmp/actual"
cmp "$tmp/expected" "$tmp/actual" || fail 'nondeterministic repo-owned content broke verification'
echo 'PASS: nondeterministic repo-owned renders verify without binding protected content'

cp "$bundle/metadata" "$tmp/metadata"
printf 'local old\n' >"$bundle/previous/src/customized.txt"
printf 'local new\n' >"$bundle/current/src/customized.txt"
# Recompute even the attacker-controlled metadata digests and binding. The
# consumer must reject because these are not the tagged template renders.
python3 - "$bundle" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
meta = json.loads((root / 'metadata').read_text())
for side in ('previous', 'current'):
    tree = root / side
    entries = []
    for path in tree.rglob('*'):
        relative = path.relative_to(tree).as_posix()
        if relative in ('.copier-answers.yml', 'src/repo-owned.txt', 'root-owned/owned.txt', 'docs/owned.txt') or relative.endswith('.code-workspace'):
            continue
        if path.is_symlink():
            entries.append([relative, '120000', path.readlink().as_posix()])
        elif path.is_dir():
            continue
        else:
            entries.append([relative, '100755' if path.stat().st_mode & 0o111 else '100644',
                            hashlib.sha256(path.read_bytes()).hexdigest()])
    meta[side + '-sha256'] = hashlib.sha256(json.dumps(sorted(entries), sort_keys=True, separators=(',', ':')).encode()).hexdigest()
meta.pop('binding-sha256')
meta['binding-sha256'] = hashlib.sha256(json.dumps(meta, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
(root / 'metadata').write_text(json.dumps(meta))
PY
if exclusions >"$tmp/refused" 2>"$tmp/error"; then fail 'crafted bundle accepted'; fi
[ ! -s "$tmp/refused" ] || fail 'refusal emitted partial exclusions'
grep -Fq 'binding' "$tmp/error" || fail 'missing binding diagnostic'
echo 'PASS: crafted customized renders and replacement metadata are refused before any exclusions'
cp "$tmp/metadata" "$bundle/metadata"
if exclusions >"$tmp/refused" 2>"$tmp/error"; then fail 'tampered render accepted'; fi
grep -Fq 'tree binding mismatch' "$tmp/error" || fail 'missing tree binding diagnostic'
printf 'old template\n' >"$bundle/previous/src/customized.txt"
printf 'new template\n' >"$bundle/current/src/customized.txt"
python3 - "$bundle/metadata" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
m = json.loads(p.read_text())
m['base'] = '0' * 40
p.write_text(json.dumps(m))
PY
if exclusions >"$tmp/refused" 2>"$tmp/error"; then fail 'tampered metadata accepted'; fi
echo 'PASS: render and metadata tampering refused'
