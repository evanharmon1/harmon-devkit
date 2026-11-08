#!/usr/bin/env bash
# Offline fixtures: real setup/session wrapper, stubbed network, and the shared
# checksum installer when developing harmon-init (not shipped in consumers).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

source = Path.cwd()
base_env = os.environ.copy()
for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
             "CLAUDE_CODE_REMOTE", "HARMON_PREFIX", "HARMON_BIN", "HARMON_VERSIONS_FILE",
             "HARMON_CHANGE_LOG", "HARMON_TMPDIR", "CLAUDE_ENV_FILE", "BASH_ENV"):
    base_env.pop(name, None)
base_env.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def resolve_tool(names, path=None):
    for name in names:
        found = shutil.which(name, path=path)
        if found:
            return found
    return None


def required_tool(names):
    found = resolve_tool(names)
    if found:
        return found
    name = " or ".join(names)
    # Same contract as test-template.sh: missing local tools skip the fixture;
    # GitHub Actions must have every capability needed by the verification gate.
    if base_env.get("GITHUB_ACTIONS"):
        print(f"FAIL: required tool '{name}' is not installed in CI", file=sys.stderr)
        raise SystemExit(1)
    print(f"SKIP: '{name}' not installed — skipping remote toolchain fixtures")
    raise SystemExit(0)


real_timeout = required_tool(("timeout", "gtimeout"))
required_tool(("sha256sum", "shasum"))
real_task = shutil.which("task")
if not real_task:
    raise SystemExit("test-reconcile-toolchain needs task")


def run_streams(args, cwd=source, env=None):
    result = subprocess.run(args, cwd=cwd, env=env or base_env, text=True, capture_output=True, timeout=20)
    return result.returncode, result.stdout, result.stderr


def run(args, cwd=source, env=None):
    rc, stdout, stderr = run_streams(args, cwd, env)
    return rc, stdout + stderr


registry = set(subprocess.check_output(["bash", "scripts/reconcile-toolchain.sh", "--list"], text=True).split())


def gate_errors(text):
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    selectors = set(re.findall(r"reconcile-toolchain\.sh[\"']?\s+--check\s+([a-z0-9_-]+)", code))
    errors = selectors - registry
    # Gate version comparisons go through --check, never a private probe/pin
    # reader that per-session preparation would not know exists.
    if re.search(r"\b[\w-]+\s+(?:--version|-version|version)\b|\b[A-Z_]+_VERSION=", code):
        errors.add("direct version check outside registry")
    return errors


selectors = set()
for gate in (source / "scripts").glob("lint-*.sh"):
    text = gate.read_text()
    assert not gate_errors(text), (gate, gate_errors(text))
    selectors.update(re.findall(r"reconcile-toolchain\.sh[\"']?\s+--check\s+([a-z0-9_-]+)", text))
assert selectors == registry, (selectors, registry)
assert gate_errors('bash scripts/reconcile-toolchain.sh --check new-tool') == {"new-tool"}
assert gate_errors('local_version="$(new-tool --version)"')
rc, out = run(["bash", "scripts/reconcile-toolchain.sh", "--check", "new-tool"])
assert rc != 0 and "unregistered" in out, out
print("OK: gate registry coverage rejects unknown tools and private gate probes")

with tempfile.TemporaryDirectory(prefix="reconcile-") as scratch:
    scratch = Path(scratch)
    resolver_bin = scratch / "resolver-bin"
    resolver_bin.mkdir()
    (resolver_bin / "gtimeout").symlink_to(real_timeout)
    assert resolve_tool(("timeout", "gtimeout"), path=str(resolver_bin)) == str(resolver_bin / "gtimeout")
    print("OK: suite timeout resolver accepts a PATH containing only gtimeout")
    repo = scratch / "checkout"
    prefix = scratch / "prefix"
    stubs = scratch / "stubs"
    for path in (repo / "scripts", repo / ".github/actions/setup", prefix / "bin", stubs):
        path.mkdir(parents=True)
    for name in ("setup-remote.sh", "session-start-remote.sh", "reconcile-toolchain.sh"):
        shutil.copyfile(source / "scripts" / name, repo / "scripts" / name)
    subprocess.run(["git", "init", "-q", str(repo)], check=True, env=base_env)
    (repo / "Taskfile.yml").write_text('version: "3"\ntasks:\n  setup:remote:\n    cmds:\n      - bash scripts/setup-remote.sh\n')
    (repo / ".github/actions/setup/action.yml").write_text("        SHELLCHECK_VERSION=7.8.9\n")
    cache = prefix / "share/harmon-remote-env"
    assets = repo / "images/devcontainer"
    (assets / "install").mkdir(parents=True)
    (cache / "install").mkdir(parents=True)
    manifest = cache / "manifest.json"
    original_manifest = {"image": {"revision": "v1.2.3"}, "tools": {"shellcheck": "1.2.3"}}
    manifest.write_text(json.dumps(original_manifest))
    log = scratch / "downloads"

    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    # Shared image installers use Linux mv -T. Keep this host fixture portable
    # while preserving its atomic, non-directory-target replacement semantics.
    real_mv = shutil.which("mv")
    executable(stubs / "mv", f'''#!/usr/bin/env python3
import os
import sys
args = sys.argv[1:]
if args[0] == "-fT":
    os.replace(args[1], args[2])
else:
    os.execv({real_mv!r}, [{real_mv!r}, *args])
''')

    def old_tool(text="1.2.3", exit_code=0):
        executable(prefix / "bin/shellcheck", f"#!/bin/sh\necho 'version: {text}'\nexit {exit_code}\n")

    binary = b"#!/bin/sh\necho 'version: 7.8.9'\n"
    archive = scratch / "shellcheck.tar.xz"
    with tarfile.open(archive, "w:xz") as tar:
        member = tarfile.TarInfo("shellcheck-v7.8.9/shellcheck")
        member.mode = 0o755
        member.size = len(binary)
        tar.addfile(member, io.BytesIO(binary))
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    pins = f"SHELLCHECK_VERSION=7.8.9\nshellcheck_amd64_sha256={checksum}\nshellcheck_arm64_sha256={checksum}\n"
    (assets / "versions.env").write_text(pins)
    real_install = source / "images/devcontainer/install/install-shellcheck.sh"
    if real_install.exists():
        for name in ("lib.sh", "install-shellcheck.sh"):
            shutil.copyfile(real_install.parent / name, assets / "install" / name)
        real_shasum = shutil.which("shasum")
        if real_shasum:
            sha_bin = scratch / "shasum-only"
            sha_bin.mkdir()
            for name in ("dirname", "shasum", "perl"):
                found = shutil.which(name)
                if found:
                    (sha_bin / name).symlink_to(found)
            sha_env = base_env | {"PATH": str(sha_bin)}
            verifier = [shutil.which("bash"), "-c", '. "$1"; harmon_verify_sha256 "$2" "$3"',
                        "_", str(real_install.parent / "lib.sh"), str(archive)]
            rc, out = run([*verifier, checksum], env=sha_env)
            assert rc == 0, out
            rc, out = run([*verifier, "0" * 64], env=sha_env)
            assert rc != 0 and "checksum mismatch" in out, out
            print("OK: shared verifier accepts shasum-only PATH and rejects a bad digest")
    else:
        # Consumers do not ship image assets. Model a bootstrap-owned installer
        # contract; harmon-init's root run above exercises the actual installer.
        (assets / "install/lib.sh").write_text("# bootstrap fixture\n")
        (assets / "install/install-shellcheck.sh").write_text('''#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -o "$tmp/archive"
tar -xJf "$tmp/archive" -C "$tmp"
cp "$tmp/shellcheck-v7.8.9/shellcheck" "$HARMON_BIN/shellcheck"
''')
    for path in assets.rglob("*"):
        if path.is_file():
            dest = cache / path.relative_to(assets)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)

    executable(stubs / "curl", '''#!/usr/bin/env bash
echo download >>"$RECONCILE_TEST_LOG"
case "${RECONCILE_TEST_MODE:-}" in
fail) exit 22 ;;
slow) sleep 10; exit 1 ;;
esac
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then cp "$RECONCILE_TEST_ARCHIVE" "$2"; exit; fi
    shift
done
exit 2
''')
    # Exercise a real timeout in milliseconds without a 30-second test delay.
    executable(stubs / "timeout", f'''#!/usr/bin/env bash
if [ "${{RECONCILE_TEST_MODE:-}}" = slow ] && [ "${{2:-}}" = 30s ]; then
    shift 2
    exec {shlex.quote(real_timeout)} --kill-after=0.5s 3s "$@"
fi

exec {shlex.quote(real_timeout)} "$@"
''')
    executable(stubs / "task", f'''#!/usr/bin/env bash
if [ "${{RECONCILE_TEST_MODE:-}}" = setup-failure ]; then exit 7; fi
exec {shlex.quote(real_task)} "$@"
''')
    env = base_env | {"CLAUDE_CODE_REMOTE": "true", "HARMON_PREFIX": str(prefix),
                      "PATH": f"{prefix / 'bin'}:{stubs}:{base_env['PATH']}",
                      "RECONCILE_TEST_LOG": str(log), "RECONCILE_TEST_ARCHIVE": str(archive),
                      "TMPDIR": str(scratch)}

    # Platform tools precede the bootstrap even in non-login agent shells.
    # Persist the export synchronously and test the exact file in fresh shells.
    competing = scratch / "platform-bin"
    competing.mkdir()
    path_tools = ("node", "npm", "uv", "yq")
    for tool in path_tools:
        executable(prefix / "bin" / tool, "#!/bin/sh\necho pinned\n")
        executable(competing / tool, "#!/bin/sh\necho platform\n")
    manifest.write_text(json.dumps(original_manifest | {"tools": {"yq": "4.0.0"}}))
    executable(prefix / "bin/task", f'#!/bin/sh\nexec {shlex.quote(real_task)} "$@"\n')
    executable(competing / "task", "#!/bin/sh\necho platform-task-must-not-run\nexit 97\n")
    shadow_env = env | {"PATH": f"{competing}:{stubs}:{prefix / 'bin'}:{base_env['PATH']}"}
    persisted = scratch / "session env.sh"
    persisted.write_text("export KEEP_OTHER_HOOK=value\n")
    rc, out, err = run_streams(["bash", "scripts/session-start-remote.sh"], repo,
                               shadow_env | {"CLAUDE_ENV_FILE": str(persisted)})
    assert rc == 0 and "setup:remote completed" in out, out
    assert "platform-task-must-not-run" not in out, out
    assert persisted.read_text().startswith("export KEEP_OTHER_HOOK=value\n"), persisted.read_text()
    assert out.count("Managed PATH saved for agent commands:") == 1, out
    assert "shadows pinned" not in out + err, (out, err)
    assert "WARNING" not in persisted.read_text(), persisted.read_text()

    # Consumers can use the hook without adopting the shared bootstrap. Even
    # with tools under the default-style bin, no manifest means no managed PATH.
    saved_manifest = manifest.with_suffix(".saved")
    platform_task = competing / "task"
    saved_platform_task = platform_task.read_text()
    incoming_path_log = scratch / "unbootstrapped-task-path"
    no_manifest_env = scratch / "no-manifest-env.sh"
    no_manifest_env.write_text("export KEEP_OTHER_HOOK=value\n")
    manifest.rename(saved_manifest)
    try:
        executable(platform_task, f'''#!/bin/sh
printf '%s\\n' "$PATH" >{shlex.quote(str(incoming_path_log))}
exec {shlex.quote(real_task)} "$@"
''')
        rc, export, diagnostics = run_streams(["bash", "scripts/reconcile-toolchain.sh", "--session-env"],
                                              repo, shadow_env)
        assert rc == 0 and not export and not diagnostics, (rc, export, diagnostics)
        rc, status = run(["bash", "scripts/reconcile-toolchain.sh", "--status"], repo, shadow_env)
        assert rc == 0 and "shadows pinned" not in status, status
        rc, out, err = run_streams(["bash", "scripts/session-start-remote.sh"], repo,
                                   shadow_env | {"CLAUDE_ENV_FILE": str(no_manifest_env)})
        assert rc == 0 and "setup:remote completed" in out, (out, err)
        assert incoming_path_log.read_text().strip() == shadow_env["PATH"], (out, err)
        assert no_manifest_env.read_text() == "export KEEP_OTHER_HOOK=value\n"
        assert "managed PATH" not in out + err and "Managed PATH" not in out + err, (out, err)
        assert "shadows pinned" not in out + err, (out, err)
    finally:
        saved_manifest.rename(manifest)
        executable(platform_task, saved_platform_task)
    print("OK: no bootstrap manifest means no export, PATH change, persistence or shadow report")
    # The shell receives a different PATH after the hook returned: the export
    # must expand it at command time, not overwrite it with the hook's snapshot.
    shell_env = shadow_env | {"PATH": f"{competing}:/later-session-entry:{base_env['PATH']}"}
    startup = scratch / "login-shell-startup.sh"
    startup.write_text(f'export PATH={shlex.quote(str(competing))}:/later-session-entry:"$PATH"\n'
                       'export LOGIN_STARTUP_FIXTURE_LOADED=yes\n')
    for login in (False, True):
        shell_args = ("bash", "--login") if login else ("bash", "--noprofile", "--norc")
        current_env = shell_env | {"BASH_ENV": str(startup), "PATH": base_env["PATH"]} if login else shell_env
        rc, out = run([*shell_args, "-c", '''
[ "$4" != True ] || [ "${LOGIN_STARTUP_FIXTURE_LOADED:-}" = yes ] || exit 1
[ "${PATH%%:*}" = "$2" ] || exit 1
incoming="$PATH"
. "$1"
[ "$PATH" = "$3:$incoming" ] || exit 1
first="$PATH"
. "$1"
[ "$PATH" = "$first" ] && [ "$KEEP_OTHER_HOOK" = value ] || exit 1
for tool in node npm uv yq; do command -v "$tool"; done
printf '%s\\n' "$PATH"
''', "_", str(persisted), str(competing), str(prefix / "bin"), str(login)], repo, current_env)
        assert rc == 0 and out.splitlines()[:4] == [str(prefix / "bin" / tool) for tool in path_tools], out
        assert ":/later-session-entry:" in out, out
    for persistence in ({}, {"CLAUDE_ENV_FILE": str(scratch / "missing/env")}):
        rc, out, err = run_streams(["bash", "scripts/session-start-remote.sh"], repo, shadow_env | persistence)
        warning = "could not persist managed PATH" if persistence else "CLAUDE_ENV_FILE is unavailable"
        assert rc == 0 and warning in out and warning not in err, (out, err)
        assert "Managed PATH saved for agent commands:" not in out + err, (out, err)
        for tool in path_tools:
            assert f"shadows pinned {tool}: resolves to '{competing / tool}'" in out, out
            assert f"shadows pinned {tool}:" not in err, err

    reconciler = repo / "scripts/reconcile-toolchain.sh"
    original_reconciler = reconciler.read_bytes()
    try:
        reconciler.write_text("#!/bin/sh\nexit 1\n")
        rc, out, err = run_streams(["bash", "scripts/session-start-remote.sh"], repo, shadow_env)
        assert rc == 0 and "could not prepare managed PATH" in out, (out, err)
        assert "could not prepare managed PATH" not in err, err
    finally:
        reconciler.write_bytes(original_reconciler)

    # Advisory helpers must not suppress the PATH fix itself. Recreate a
    # present-but-broken Python and a failing manifest reader (exit 127).
    failing_helpers = scratch / "failing-helpers"
    failing_helpers.mkdir()
    for helper in ("python3", "jq"):
        executable(failing_helpers / helper, "#!/bin/sh\nexit 127\n")
    helper_env = shadow_env | {"PATH": f"{failing_helpers}:{shadow_env['PATH']}"}
    rc, export, diagnostics = run_streams(["bash", "scripts/reconcile-toolchain.sh", "--session-env"],
                                          repo, helper_env)
    assert rc == 0 and 'export PATH=' in export and "WARNING" not in export, (rc, export, diagnostics)
    rc, out = run(["bash", "-c", export + '\nprintf "%s\\n" "${PATH%%:*}"'], repo, helper_env)
    assert rc == 0 and out.strip() == str(prefix / "bin"), out
    print("OK: --session-env still prints a working export with helpers that exit 127")
    rc, out = run(["bash", "scripts/reconcile-toolchain.sh", "--status"], repo, shadow_env)
    assert rc == 0 and all(str(competing / tool) in out for tool in path_tools), out
    # Shell data in a custom bin path must survive export generation literally.
    awkward_bin = scratch / "bin with 'quotes $dollar; characters"
    result = subprocess.run(["bash", "scripts/reconcile-toolchain.sh", "--session-env"], cwd=repo,
                            env=env | {"HARMON_BIN": str(awkward_bin)},
                            capture_output=True, text=True, timeout=20)
    rc, out = run(["bash", "-c", result.stdout + '\nprintf "%s\\n" "${PATH%%:*}"'], repo, env)
    assert rc == 0 and out.strip() == str(awkward_bin), out
    for tool in (*path_tools, "task"):
        (prefix / "bin" / tool).unlink()
    (competing / "task").unlink()
    manifest.write_text(json.dumps(original_manifest))
    log.unlink(missing_ok=True)
    print("OK: SessionStart persists managed PATH before task; login/non-login shells resolve pinned tools; unavailable persistence names shadows")

    def setup(mode="", remote=True):
        log.unlink(missing_ok=True)
        current_env = env | {"RECONCILE_TEST_MODE": mode}
        if not remote:
            current_env.pop("CLAUDE_CODE_REMOTE")
        rc, output = run(["task", "--silent", "setup:remote"], repo, current_env)
        assert rc == 0, output
        return output

    def drift_warning(output, reason, remedy=None):
        line = next(line for line in output.splitlines() if line.startswith("==> setup:remote completed with warnings:"))
        for value in ("shellcheck", "installed 1.2.3", "checkout pin 7.8.9", "environment v1.2.3",
                      reason):
            assert value in line, (value, output)
        if remedy is None:
            assert "HARMON_INIT_REF" in line and "release carrying shellcheck 7.8.9" in line, output
        else:
            assert remedy in line and "HARMON_INIT_REF" not in line, output
        assert "latest release" not in line, output

    old_tool()
    out = setup()
    assert "Reconciled shellcheck 1.2.3 -> 7.8.9" in out and "completed with warnings" not in out, out
    assert (prefix / "bin/shellcheck").read_bytes() == binary
    assert log.exists()
    out = setup()
    assert not log.exists() and "WARNING" not in out and "Reconciled" not in out, out
    print("OK: task setup:remote installs the checkout pin and matching versions do not install/warn")

    missing_tmp = scratch / "missing-tmpdir"
    assert not missing_tmp.exists()
    bad_tmp_env = env | {"TMPDIR": str(missing_tmp)}
    rc, out = run(["bash", "scripts/reconcile-toolchain.sh", "--check", "shellcheck"], repo, bad_tmp_env)
    assert rc == 0 and not out, out
    print("OK: --check at the pinned version succeeds with a missing TMPDIR")
    for args in (["--status"], []):
        rc, out = run(["bash", "scripts/reconcile-toolchain.sh", *args], repo, bad_tmp_env)
        assert rc == 0 and "WARNING: shellcheck version probe: mktemp failed" in out, out
        assert str(missing_tmp) in out and "installed unknown" not in out and "checkout pin" not in out, out
        assert not log.exists(), out
    print("OK: bounded probe allocation failure reports mktemp/TMPDIR rather than unknown version drift")

    for mode, reason in (("fail", "installer failed"), ("slow", "time budget exhausted")):
        old_tool()
        before = (prefix / "bin/shellcheck").read_bytes()
        out = setup(mode)
        drift_warning(out, reason)
        assert log.exists() and (prefix / "bin/shellcheck").read_bytes() == before, (mode, log.exists(), out)
    print("OK: failed downloads and exhausted install budgets warn with all required fields, exit 0, preserve old tool")

    old_tool()
    out = setup(remote=False)
    assert not log.exists() and "shellcheck" not in out and "WARNING" not in out, out
    assert "1.2.3" in (prefix / "bin/shellcheck").read_text()
    print("OK: local preparation does not reconcile")

    # The generated-repository path has no images/, so uses persisted assets.
    shutil.rmtree(repo / "images")
    out = setup()
    assert "Reconciled shellcheck" in out and log.exists(), out
    old_tool()
    rc, out = run(["bash", "scripts/session-start-remote.sh"], repo, env)
    assert rc == 0, out
    line = next(line for line in out.splitlines() if line.startswith("==> SessionStart remote preparation:"))
    assert "Reconciled shellcheck 1.2.3 -> 7.8.9" in line, out
    old_tool()
    installer = cache / "install/install-shellcheck.sh"
    installer.rename(installer.with_suffix(".saved"))
    out = setup()
    drift_warning(out, "shared installer unavailable")
    assert not log.exists(), out
    installer.with_suffix(".saved").rename(installer)
    executable(stubs / "shellcheck", "#!/bin/sh\necho 'version: 1.2.3'\n")
    log.unlink(missing_ok=True)
    rc, out = run(["task", "--silent", "setup:remote"], repo,
                  env | {"PATH": f"{stubs}:{prefix / 'bin'}:{base_env['PATH']}"})
    assert rc == 0 and log.exists() and "Reconciled shellcheck 1.2.3 -> 7.8.9" in out, out
    assert f"incoming PATH shadows pinned shellcheck: resolves to '{stubs / 'shellcheck'}'" in out, out
    log.unlink()
    rc, out = run(["bash", "scripts/reconcile-toolchain.sh", "--status"], repo,
                  env | {"PATH": f"{stubs}:{prefix / 'bin'}:{base_env['PATH']}"})
    assert rc == 0 and not log.exists(), out
    line = next(line for line in out.splitlines() if line.startswith("WARNING: shellcheck installed"))
    for value in ("installed 1.2.3", "checkout pin 7.8.9", "environment v1.2.3",
                  "must be writable and precede",
                  f"make {prefix / 'bin'} writable and place it before other shellcheck copies on PATH"):
        assert value in line, (value, out)
    assert "HARMON_INIT_REF" not in line and "rebuild the environment" not in line, out
    print("OK: --status shares the shadowed-prefix cause and remedy without installing or advising a rebuild")
    (stubs / "shellcheck").unlink()
    print("OK: setup fixes PATH before reconciling; status only diagnoses shadows; missing installers warn without installing")
    action = repo / ".github/actions/setup/action.yml"
    action.write_text("SHELLCHECK_VERSION=7.8.9\nSHELLCHECK_VERSION=7.8.8\n")
    out = setup()
    line = next(line for line in out.splitlines() if line.startswith("==> setup:remote completed with warnings:"))
    assert "multiple SHELLCHECK_VERSION pins" in line and "keep exactly one SHELLCHECK_VERSION assignment" in line, out
    assert str(action) in line and "HARMON_INIT_REF" not in line and "release carrying" not in line, out
    assert not log.exists(), out
    action.write_text("SHELLCHECK_VERSION=7.8.9\n")
    print("OK: duplicate pins advise correcting the checkout configuration rather than rebuilding the environment")
    old_tool()
    cached_pins = cache / "versions.env"
    cached_pins.write_text(pins.replace("7.8.9", "7.8.8"))
    out = setup()
    drift_warning(out, "checksum metadata")
    assert not log.exists(), out
    cached_pins.write_text(pins)
    if real_install.exists():
        cached_pins.write_text(pins.replace(checksum, "0" * 64))
        out = setup()
        drift_warning(out, "installer failed")
        assert "checksum mismatch" in out and "1.2.3" in (prefix / "bin/shellcheck").read_text(), out
        cached_pins.write_text(pins)
    print("OK: generated checkouts reuse cached assets; missing checksum coverage cannot install")
    if real_install.exists():
        print("OK: a bad digest rejects the archive before replacing the existing tool")

    # The environment release number is deliberately unrelated to the tool's
    # version. Numeric tuple comparison must recognize 7.8.10 > 7.8.9.
    old_tool("7.8.10")
    cached_pins.write_text(pins.replace("7.8.9", "7.8.10"))
    manifest.write_text(json.dumps({"image": {"revision": "v1.2.3"}, "tools": {"shellcheck": "7.8.10"}}))
    out = setup()
    assert not log.exists(), out
    line = next(line for line in out.splitlines() if line.startswith("==> setup:remote completed with warnings:"))
    for value in ("installed 7.8.10", "checkout pin 7.8.9", "environment v1.2.3",
                  "update the repository's shellcheck pin", "7.8.10", "copier update"):
        assert value in line, (value, out)
    assert "HARMON_INIT_REF" not in line and "latest release" not in line, out
    manifest.write_text(json.dumps(original_manifest))
    cached_pins.write_text(pins)
    old_tool()
    print("OK: a newer recorded tool pin advises a repository update instead of the latest environment release")

    for mode in ("setup-failure",):
        rc, out = run(["bash", "scripts/session-start-remote.sh"], repo, env | {"RECONCILE_TEST_MODE": mode})
        assert rc == 0, out
        line = next(line for line in out.splitlines()
                    if line.startswith("==> WARNING: SessionStart remote preparation: setup:remote failed;"))
        for value in ("shellcheck", "installed 1.2.3", "checkout pin 7.8.9", "environment v1.2.3", "HARMON_INIT_REF",
                      "preparation left this tool unreconciled"):
            assert value in line, (mode, value, out)
        assert "within its time budget" not in line, out
    print("OK: preparation failure reports drift without inventing a timeout cause")

    executable(stubs / "timeout", f'''#!/usr/bin/env bash
if [ "${{1:-}}" = 90s ]; then
    shift
    exec {shlex.quote(real_timeout)} 0.1s "$@"
fi
exec {shlex.quote(real_timeout)} "$@"
''')
    executable(stubs / "task", '''#!/usr/bin/env bash
trap 'echo TERM >>"$RECONCILE_SIGNALS"' TERM
trap 'echo INT >>"$RECONCILE_SIGNALS"' INT
trap 'echo HUP >>"$RECONCILE_SIGNALS"' HUP
echo "$$" >"$RECONCILE_PID"
sleep 1
echo complete >"$RECONCILE_DONE"
''')
    signal_file, pid_file, done_file = (scratch / name for name in ("signals", "setup.pid", "setup.done"))
    current_env = env | {"RECONCILE_SIGNALS": str(signal_file), "RECONCILE_PID": str(pid_file),
                         "RECONCILE_DONE": str(done_file)}
    rc, out = run(["bash", "scripts/session-start-remote.sh"], repo, current_env)
    try:
        assert rc == 0 and "setup:remote still running" in out, out
        os.kill(int(pid_file.read_text()), 0)
        assert not signal_file.exists(), signal_file.read_text()
        assert not done_file.exists(), out
        assert "unreconciled" not in out and "failed" not in out, out
    finally:
        for _ in range(200):
            if done_file.exists():
                break
            time.sleep(0.01)
    assert done_file.read_text().strip() == "complete"
    assert not signal_file.exists(), signal_file.read_text()
    print("OK: a SessionStart deadline reports running setup without signals or a fabricated drift/failure cause")
    executable(stubs / "task", f'''#!/usr/bin/env bash
if [ "${{RECONCILE_TEST_MODE:-}}" = setup-failure ]; then exit 7; fi
exec {shlex.quote(real_task)} "$@"
''')
    executable(stubs / "timeout", f'#!/usr/bin/env bash\nexec {shlex.quote(real_timeout)} "$@"\n')

    # This child escapes timeout's process group and retains stdout for 8s
    # after the version command exits. A pipe capture used to wait for it.
    executable(prefix / "bin/shellcheck", f'''#!/usr/bin/env bash
exec {shlex.quote(sys.executable)} - <<'PYPROBE'
import subprocess
import sys
subprocess.Popen([sys.executable, "-c", "import time; time.sleep(8)"],
                 start_new_session=True, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("version: 1.2.3", flush=True)
PYPROBE
''')
    for args, mode in ((["bash", "scripts/reconcile-toolchain.sh", "--status"], ""),
                       (["bash", "scripts/session-start-remote.sh"], "setup-failure")):
        started = time.monotonic()
        rc, out = run(args, repo, env | {"RECONCILE_TEST_MODE": mode})
        elapsed = time.monotonic() - started
        assert rc == 0 and "installed 1.2.3" in out, out
        # The actual probe budget is 2s + 1s kill grace; allow 0.5s for the
        # wrapper/metadata probes. Waiting for the 8s child fails decisively.
        assert elapsed < 3.5, (args, elapsed, out)
        print(f"OK: stdout-holding descendant cannot extend {args[1]} beyond the probe budget ({elapsed:.2f}s)")

print("reconcile-toolchain OK")
PY
