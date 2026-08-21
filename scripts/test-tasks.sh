#!/usr/bin/env bash
# test-tasks.sh — guard the Taskfile against regressions that only surface at
# run time: a Taskfile that no longer compiles, and setup tasks that fail when
# they should be safe no-ops. Run via `task test:tasks`.
#
# Coverage note: the bootstrap assertion only exercises the "Homebrew already
# installed" path, so it is skipped on runners without brew (e.g. the default
# ubuntu-latest CI). It still guards the common local/macOS case — the exact
# regression where `task bootstrap` aborted on a sudo precheck despite brew
# already being installed.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

echo "==> Taskfile compiles (every task parses)"
if ! task --list-all >/dev/null 2>&1; then
    fail "task --list-all failed — the Taskfile does not compile"
fi

echo "==> bootstrap is a no-op when Homebrew is already installed"
# Run against STUBS, never the real toolchain. `test:tasks` is part of `verify`,
# and in a generated use_node repo `bootstrap` runs `brew install node` plus
# the pnpm bootstrap helper — so invoking it for real made running the tests mutate
# the developer's machine, and CI too (GitHub's ubuntu images carry linuxbrew on
# PATH). A test must not install a global toolchain as a side effect.
#
# Stubbing also removes the old `command -v brew` skip, so the assertion now
# runs everywhere instead of silently doing nothing on most CI runners.
bootstrap_bin="${test_tmp}/bootstrap-bin"
installer_marker="${test_tmp}/homebrew-installer-fetched"
brew_prefix="${test_tmp}/homebrew"
pnpm_prefix="${brew_prefix}/opt/pnpm"
mkdir -p "$bootstrap_bin"
for stub in npm node pnpm; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${bootstrap_bin}/${stub}"
    chmod +x "${bootstrap_bin}/${stub}"
done
mkdir -p "${brew_prefix}/bin" "${pnpm_prefix}/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${pnpm_prefix}/bin/pnpm"
chmod +x "${pnpm_prefix}/bin/pnpm"
ln -s "${pnpm_prefix}/bin/pnpm" "${brew_prefix}/bin/pnpm"
cat >"${bootstrap_bin}/brew" <<EOF
#!/usr/bin/env bash
case "\$*" in
--prefix) printf '%s\\n' "${brew_prefix}" ;;
"--prefix pnpm") printf '%s\\n' "${pnpm_prefix}" ;;
esac
exit 0
EOF
chmod +x "${bootstrap_bin}/brew"
# Fake curl records any attempt to fetch the Homebrew installer, so we can prove
# the `command -v brew` guard short-circuited instead of re-running setup.
cat >"${bootstrap_bin}/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
    *Homebrew/install*) : >"${installer_marker}" ;;
    esac
done
exit 0
EOF
chmod +x "${bootstrap_bin}/curl"

if ! PATH="${bootstrap_bin}:${PATH}" task bootstrap >/dev/null 2>&1; then
    fail "task bootstrap failed with brew already on PATH"
fi
if [ -f "$installer_marker" ]; then
    fail "task bootstrap fetched the Homebrew installer despite brew being on PATH"
fi

if [ -x scripts/bootstrap-pnpm.sh ]; then
    echo "==> pnpm bootstrap migrates legacy npm-global ownership to Homebrew"
    pnpm_test_bin="${test_tmp}/pnpm-test-bin"
    pnpm_brew_prefix="${test_tmp}/pnpm-homebrew"
    pnpm_cellar="${pnpm_brew_prefix}/Cellar/pnpm/11.0.0"
    pnpm_opt="${pnpm_brew_prefix}/opt/pnpm"
    pnpm_legacy="${pnpm_brew_prefix}/lib/node_modules/pnpm"
    pnpm_uninstall_marker="${test_tmp}/pnpm-uninstalled"
    pnpm_install_entry_marker="${test_tmp}/pnpm-install-entry"
    mkdir -p "$pnpm_test_bin" "${pnpm_brew_prefix}/bin" "${pnpm_brew_prefix}/opt" "${pnpm_cellar}/bin" "$pnpm_legacy"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${pnpm_cellar}/bin/pnpm"
    chmod +x "${pnpm_cellar}/bin/pnpm"
    ln -s "$pnpm_cellar" "$pnpm_opt"
    ln -s "${pnpm_legacy}/bin/pnpm.cjs" "${pnpm_brew_prefix}/bin/pnpm"
    cat >"${pnpm_test_bin}/brew" <<EOF
#!/usr/bin/env bash
case "\$*" in
"install node") : >"${pnpm_install_entry_marker}" ;;
"install pnpm") exit 1 ;;
"list --formula pnpm") exit 0 ;;
bundle\ --file=*)
    case "\$(readlink "${pnpm_brew_prefix}/bin/pnpm")" in
    "${pnpm_legacy}"/*) exit 1 ;;
    esac
    ;;
--prefix) printf '%s\\n' "${pnpm_brew_prefix}" ;;
"--prefix pnpm") printf '%s\\n' "${pnpm_opt}" ;;
"unlink pnpm")
    [ ! -L "${pnpm_brew_prefix}/bin/pnpm" ] || unlink "${pnpm_brew_prefix}/bin/pnpm"
    ;;
"link --overwrite pnpm")
    ln -s "${pnpm_cellar}/bin/pnpm" "${pnpm_brew_prefix}/bin/pnpm"
    ;;
*) exit 1 ;;
esac
EOF
    chmod +x "${pnpm_test_bin}/brew"
    cat >"${pnpm_test_bin}/npm" <<EOF
#!/usr/bin/env bash
[ "\$*" = "uninstall --global --prefix ${pnpm_brew_prefix} pnpm" ] || exit 1
rmdir "${pnpm_legacy}"
: >"${pnpm_uninstall_marker}"
EOF
    chmod +x "${pnpm_test_bin}/npm"
    for stub in pnpm lefthook uv; do
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${pnpm_test_bin}/${stub}"
        chmod +x "${pnpm_test_bin}/${stub}"
    done
    printf '%s\n' '#!/usr/bin/env bash' 'exit 127' >"${pnpm_test_bin}/realpath"
    chmod +x "${pnpm_test_bin}/realpath"
    PATH="${pnpm_test_bin}:${PATH}" ./scripts/bootstrap-pnpm.sh >/dev/null
    [ -f "$pnpm_uninstall_marker" ] ||
        fail "pnpm bootstrap did not retire the Homebrew-prefix npm package"
    [ "$(readlink "${pnpm_brew_prefix}/bin/pnpm")" = "${pnpm_cellar}/bin/pnpm" ] ||
        fail "pnpm bootstrap did not transfer executable ownership to Homebrew"
    if [ "$(grep -c -- './scripts/bootstrap-pnpm.sh' Taskfile.yml)" -ge 2 ]; then
        unlink "$pnpm_install_entry_marker"
        unlink "${pnpm_brew_prefix}/bin/pnpm"
        mkdir -p "$pnpm_legacy"
        ln -s "${pnpm_legacy}/bin/pnpm.cjs" "${pnpm_brew_prefix}/bin/pnpm"
        PATH="${pnpm_test_bin}:${PATH}" task install >/dev/null
        [ -f "$pnpm_install_entry_marker" ] ||
            fail "task install did not invoke the pnpm ownership migration"
    fi
fi

if [ -n "${HARMON_TEST_PNPM_BOOTSTRAP_ONLY:-}" ]; then
    exit 0
fi

echo "==> Semgrep wrapper preserves explicit scan targets"
semgrep_bin="${test_tmp}/semgrep-bin"
semgrep_args="${test_tmp}/semgrep-args"
mkdir -p "$semgrep_bin"
cat >"${semgrep_bin}/uvx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SEMGREP_ARGS:?}"
EOF
chmod +x "${semgrep_bin}/uvx"
PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" \
    ./scripts/run-semgrep.sh scripts
[ "$(tail -n 1 "$semgrep_args")" = "scripts" ] ||
    fail "Semgrep wrapper did not preserve the explicit target"
if grep -Fxq . "$semgrep_args"; then
    fail "Semgrep wrapper appended a repository-wide target"
fi

echo "==> shell formatter preserves tracked paths and failures"
format_repo="${test_tmp}/format-repo"
# Assemble the jinja-style segment so this file never contains a literal
# copier marker: the standardize-repo skill's unrendered-marker scan
# (verify-applied.sh) would otherwise flag scripts/test-tasks.sh in every
# generated repo. The RUNTIME path still opens a real block marker ("[%"
# followed by " if ... %]") plus whitespace — the case the repo's shell
# formatter helper must survive.
jinja_open='[%'
format_path="${format_repo}/template/${jinja_open} if sample %]/script with spaces.sh"
mkdir -p "$(dirname "$format_path")"
git -C "$format_repo" init -q
printf '%s\n' '#!/usr/bin/env bash' 'if true;then' 'echo ok' 'fi' >"$format_path"
git -C "$format_repo" add -- "${format_path#"$format_repo"/}"
(
    cd "$format_repo"
    "$repo/scripts/shell-quality.sh" format
)
if ! shfmt -d "$format_path" >/dev/null; then
    fail "shell formatter did not safely format a tracked path containing spaces"
fi

format_fail_bin="${test_tmp}/format-fail-bin"
mkdir -p "$format_fail_bin"
cat >"${format_fail_bin}/shfmt" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "${format_fail_bin}/shfmt"
if (
    cd "$format_repo"
    PATH="${format_fail_bin}:${PATH}" "$repo/scripts/shell-quality.sh" format
); then
    fail "shell formatter masked a shfmt failure"
fi
if ! grep -qF './scripts/shell-quality.sh format' Taskfile.yml; then
    fail "Taskfile.yml does not delegate shell formatting to the path-safe helper"
fi

echo "==> secret helper tasks reject missing destination metadata"
# Assert the stable missing-destination diagnostic, not just a nonzero exit:
# a bare `if ! task ...` would also be satisfied by an unrelated failure
# (missing op/gh, a Taskfile parse error). Clear any inherited destination
# metadata first so the tests actually exercise the missing-metadata path.
out=$(printf '%s' 'dummy-secret' |
    env -u VAULT -u ITEM -u FIELD -u SECTION task secret:set:1p 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:1p succeeded without destination metadata"
fi
case "$out" in
*"VAULT, ITEM, and FIELD are required"*) ;;
*) fail "task secret:set:1p failed for the wrong reason: $out" ;;
esac
out=$(printf '%s' 'dummy-secret' |
    env -u NAME -u REPO task secret:set:gh 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:gh succeeded without destination metadata"
fi
case "$out" in
*"NAME and REPO are required"*) ;;
*) fail "task secret:set:gh failed for the wrong reason: $out" ;;
esac

echo "==> 1Password helper rejects SSH Key categories at runtime"
op_bin="${test_tmp}/op-bin"
op_edit_called="${test_tmp}/op-edit-called"
mkdir -p "$op_bin"
cat >"${op_bin}/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"item get")
    printf '{"category":"%s","fields":[{"label":"password","type":"CONCEALED","value":"old"}]}\n' \
        "${OP_FIXTURE_CATEGORY:?}"
    ;;
"item edit")
    : >"${OP_EDIT_CALLED:?}"
    cat >/dev/null
    ;;
*)
    exit 1
    ;;
esac
EOF
chmod +x "${op_bin}/op"
for category in SSH_KEY SSHKEY; do
    rm -f "$op_edit_called"
    out=$(printf '%s' 'dummy-secret' |
        PATH="${op_bin}:${PATH}" OP_FIXTURE_CATEGORY="$category" \
            OP_EDIT_CALLED="$op_edit_called" VAULT=test ITEM=test FIELD=password \
            ./scripts/secret-set-1p.sh 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "secret:set:1p accepted unsupported category $category"
    fi
    case "$out" in
    *"item holds a passkey or SSH key"*) ;;
    *) fail "secret:set:1p rejected $category for the wrong reason: $out" ;;
    esac
    if [ -e "$op_edit_called" ]; then
        fail "secret:set:1p attempted an item edit for $category"
    fi
done

echo "==> secret helpers print styled outcomes without echoing secret values"
secret_value='sensitive-value-must-not-appear'
rm -f "$op_edit_called"
out=$(printf '%s' "$secret_value" |
    PATH="${op_bin}:${PATH}" OP_FIXTURE_CATEGORY=LOGIN \
        OP_EDIT_CALLED="$op_edit_called" VAULT=test ITEM=test FIELD=password \
        ./scripts/secret-set-1p.sh 2>&1) || fail "secret:set:1p success fixture failed: $out"
[ -e "$op_edit_called" ] || fail "secret:set:1p success fixture never edited the item"
case "$out" in
*'DONE: 1Password secret updated'*) ;;
*) fail "secret:set:1p omitted its final outcome: $out" ;;
esac
case "$out" in
*"$secret_value"*) fail "secret:set:1p printed the secret value" ;;
esac

gh_bin="${test_tmp}/gh-bin"
gh_secret_capture="${test_tmp}/gh-secret"
mkdir -p "$gh_bin"
cat >"${gh_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-} ${2:-}" = "secret set" ] || exit 1
cat >"${GH_SECRET_CAPTURE:?}"
EOF
chmod +x "${gh_bin}/gh"
out=$(printf '%s' "$secret_value" |
    PATH="${gh_bin}:${PATH}" GH_SECRET_CAPTURE="$gh_secret_capture" \
        NAME=DEPLOY_TOKEN REPO=owner/repo ./scripts/secret-set-gh.sh 2>&1) ||
    fail "secret:set:gh success fixture failed: $out"
[ "$(cat "$gh_secret_capture")" = "$secret_value" ] ||
    fail "secret:set:gh changed the secret value sent to gh"
case "$out" in
*'DONE: GitHub secret updated'*) ;;
*) fail "secret:set:gh omitted its final outcome: $out" ;;
esac
case "$out" in
*"$secret_value"*) fail "secret:set:gh printed the secret value" ;;
esac

echo "==> terminal-aware tasks stay interactive through Task grouping, in both twins"
# A run-time-only regression, and a total one: this Taskfile sets `output:
# group` GLOBALLY, so Task pipes each task's stdout. A script guarding on
# `[ -t 1 ]` then sees a pipe and refuses even in a real terminal, which made
# `task setup:gh-scopes` impossible to use through its own documented entry
# point (the smoke tests called the script directly and never saw the wiring).
# `interactive: true` makes Task skip grouping and attach the task to the
# terminal.
#
# Pinned for BOTH twins, because a generated repo inherits the same global
# grouping and would inherit the same defect. Asserted against the file rather
# than by running the task: running it would open a real browser device-code
# flow against the operator's own credential.
#
# Keyed to a fatal `-t 1` check specifically. A `-t 0` guard (secret:set:*,
# codex:gate:disable) is untouched by output grouping, which redirects stdout
# only. The status tasks do not refuse without a TTY, but their intentionally
# visual dashboard would otherwise lose color, Unicode, and gum through its
# documented Task entrypoints.
# Both layers where they exist. A GENERATED repo has only the first — it is the
# rendered output, with no template/ of its own — so a missing file is skipped
# rather than failed, and the counter below keeps "skipped everything" from
# passing silently.
tty_gated_tasks="setup:gh-scopes status status:git status:gh status:creds status:code status:env status:setup"
checked_taskfiles=0
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    checked_taskfiles=$((checked_taskfiles + 1))
    for t in $tty_gated_tasks; do
        block="$(awk -v name="  ${t}:" '
            $0 == name { inblock = 1; next }
            inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
            inblock { print }
        ' "$taskfile")"
        [ -n "$block" ] || fail "${taskfile}: task ${t} not found — did it get renamed?"
        # A whole-line DIRECTIVE, never a substring: the task carries a comment
        # explaining why the key is there, and that comment names the key — so a
        # substring match passes on the prose alone and the assertion silently
        # stops asserting. (It did, until a mutation test caught it.)
        printf '%s\n' "$block" |
            grep -vE '^[[:space:]]*#' |
            grep -qE '^[[:space:]]*interactive:[[:space:]]*true[[:space:]]*$' ||
            fail "${taskfile}: ${t} lacks 'interactive: true' — global 'output: group' hides its terminal from the script"
    done
done

[ "$checked_taskfiles" -gt 0 ] ||
    fail "no Taskfile was checked for the interactive: true requirement — the assertion above proved nothing"

# The guard above is worth nothing if the grouping it defends against is gone;
# in that case the requirement should be re-derived rather than silently kept.
# GROUP specifically, not merely the presence of an `output:` key: `interleaved`
# and `prefixed` keep the key while dropping the stdout pipe that makes
# `interactive: true` necessary, and a check on the key alone would keep
# demanding it long after the reason had evaporated.
awk '
    /^output:/ { inout = 1; next }
    inout && /^[^[:space:]]/ { inout = 0 }
    inout && /^[[:space:]]+group:[[:space:]]*$/ { found = 1 }
    END { exit(found ? 0 : 1) }
' Taskfile.yml ||
    fail "Taskfile.yml no longer selects 'output: group' — re-derive whether the interactive: true assertion above still describes a real hazard"

echo "==> setup:github delegates action logic to the tested script in both twins"
checked_setup_tasks=0
for taskfile in Taskfile.yml template/Taskfile.yml.jinja; do
    [ -f "$taskfile" ] || continue
    checked_setup_tasks=$((checked_setup_tasks + 1))
    block="$(awk '
        $0 == "  setup:github:" { inblock = 1; next }
        inblock && /^  [a-zA-Z0-9]/ { inblock = 0 }
        inblock { print }
    ' "$taskfile")"
    [ -n "$block" ] || fail "${taskfile}: setup:github task not found"
    printf '%s\n' "$block" | grep -Fq './scripts/setup-github.sh --repo "{{.REPO}}"' ||
        fail "${taskfile}: setup:github does not delegate to scripts/setup-github.sh"
    if printf '%s\n' "$block" | grep -Eq 'gh api|^[[:space:]]*-[[:space:]]*\|'; then
        fail "${taskfile}: setup:github contains inline action logic instead of a trivial script command"
    fi
done
[ "$checked_setup_tasks" -gt 0 ] || fail "no Taskfile setup:github wiring was checked"

if [ -x ./scripts/test-terraform-provider-locks.sh ]; then
    echo "==> Terraform provider locks cover developer and CI platforms"
    ./scripts/test-terraform-provider-locks.sh
fi

if [ -x ./scripts/test-terraform-changed.sh ]; then
    echo "==> Terraform change detection drives the required terraform-verify check"
    ./scripts/test-terraform-changed.sh
fi

echo "==> task targets OK (compile + bootstrap idempotency + path-safe formatting)"
