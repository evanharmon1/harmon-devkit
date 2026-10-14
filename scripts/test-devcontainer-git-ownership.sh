#!/usr/bin/env bash
# test-devcontainer-git-ownership.sh — regression coverage for bind-mounted
# workspace permissions, exact Git trust, and repository-managed hooks.
#
# The fixture exercises the real permissions reconciliation helper with a
# logging sudo shim. The Linux bot devcontainer smoke test remains the decisive
# check of a real UID-mismatched bind mount and host-runner checkout.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_script="scripts/test-devcontainer-git-ownership.sh"
post_create=".devcontainer/scripts/post-create-common.sh"
template_common="template/[% if devcontainer %].devcontainer[% endif %]/scripts/post-create-common.sh"
bot_post_create=".devcontainer/post-create.sh"
template_bot_post_create="template/[% if devcontainer %].devcontainer[% endif %]/post-create.sh.jinja"
template_test="template/scripts/[% if devcontainer %]test-devcontainer-git-ownership.sh[% endif %]"

for required_file in "$test_script" "$post_create" "$bot_post_create"; do
    [ -r "$required_file" ] || fail "$required_file not found"
done
# The root checkout owns the Copier source tree and its dogfood answers. A
# generated consumer may legitimately have a project directory named
# "template", so the directory name alone is not a root-repository marker.
if [ -f .dogfood-answers.yml ] && [ -d template ]; then
    for required_file in "$template_common" "$template_bot_post_create" "$template_test"; do
        [ -r "$required_file" ] || fail "$required_file not found"
    done
    cmp -s "$post_create" "$template_common" ||
        fail "root and template permissions helpers diverged"
    cmp -s "$test_script" "$template_test" ||
        fail "root and template focused tests diverged"
fi

# Extract the production helper verbatim. This keeps the fixture attached to
# the implementation instead of growing a second, drifting permissions routine.
tmp_root="$(mktemp -d -t harmon-git-ownership-XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT
helpers="$tmp_root/workspace-permissions.sh"
sed -n '/^resolve_workspace_root()/,/^# --- End workspace permissions reconciliation ---$/p' "$post_create" | sed '$d' >"$helpers"
[ -s "$helpers" ] || fail "could not extract workspace permissions helpers"
grep -q '^reconcile_workspace_permissions()' "$helpers" ||
    fail "the extracted helpers do not include reconcile_workspace_permissions"
grep -q '^resolve_git_dir()' "$helpers" ||
    fail "the extracted helpers do not include resolve_git_dir"
! grep -Fq 'a+rwX' "$helpers" ||
    fail "permissions reconciliation still grants world-writable Git metadata permissions"
# "hard link"/"hard-link" is deliberately NOT in this guard: F23 (review
# round 3) legitimately scopes the ownership/mode mutation by link count
# (`-links 1`), a narrow, necessary exclusion — not the kind of open-ended
# recursive-filesystem heuristic (crossing mountpoints, rewriting Git's own
# hooksPath config) this guard exists to keep out.
! grep -Eq 'mountpoint|core[.]hooksPath' "$helpers" ||
    fail "permissions reconciliation retained recursive filesystem policy"
grep -Fq '[ -L "$candidate/.git" ]' "$helpers" ||
    fail "permissions reconciliation does not reject symlinked Git markers"
grep -Fq 'git_dir="$(resolve_git_dir "$workspace_root")"' "$helpers" ||
    fail "permissions reconciliation does not resolve the real Git directory before touching it"
grep -Fq 'reverse_pointer="$(cat "$admin_dir/gitdir" 2>/dev/null)"' "$helpers" ||
    fail "resolve_git_dir does not require the worktree admin dir's reverse pointer before trusting it (#1241 challenge round 6, finding F17)"
grep -Fq '[ "$reverse_pointer_resolved" = "$git_marker" ]' "$helpers" ||
    fail "resolve_git_dir does not validate the reverse pointer round-trips to this exact workspace"
grep -Fq '[ "$(dirname "$admin_dir")" = "$git_dir/worktrees" ]' "$helpers" ||
    fail "resolve_git_dir does not validate the admin dir is a direct worktrees/ child of the resolved common dir (#1241 review round 1, finding F19)"
grep -q '^resolve_relative_to()' "$helpers" ||
    fail "the extracted helpers do not include resolve_relative_to (#1241 review round 1, finding F21)"
grep -Fq 'if [ "$admin_dir" = "$git_dir" ]; then' "$helpers" ||
    fail "resolve_git_dir does not skip privileged reconciliation for non-worktree .git indirection (#1241 review round 2, finding F22)"
grep -q '^reconcile_git_metadata_ownership()' "$helpers" ||
    fail "the extracted helpers do not include reconcile_git_metadata_ownership (#1241 review round 2, finding F22)"
grep -Fq "orig_gid=\"\$(stat -c '%g' \"\$git_dir\"" "$helpers" ||
    fail "permissions reconciliation does not capture the original group before reassigning ownership"
grep -Fq '-exec chown "$(id -u):${orig_gid}" {} +' "$helpers" ||
    fail "permissions reconciliation does not preserve the original group when reclaiming ownership"
grep -Fq '-exec chmod u=rwX,g=rwX,o=rX {} +' "$helpers" ||
    fail "permissions reconciliation does not grant the original group write access"
grep -Fq '\( -type d -o \( -type f -a -links 1 \) \)' "$helpers" ||
    fail "permissions reconciliation does not scope ownership/mode changes to directories and single-linked files (#1241 review round 3, finding F23)"
grep -Fq 'sudo find "$git_dir" -type d -exec chmod g+s {} +' "$helpers" ||
    fail "permissions reconciliation does not set the setgid bit (scoped to directories only, privileged so it survives a non-member gid) so new entries inherit the original group"
grep -Fq 'git -c safe.directory="$workspace_root" -C "$workspace_root" config core.sharedRepository 0664' "$helpers" ||
    fail "permissions reconciliation does not configure an explicit, umask-independent core.sharedRepository so future commits stay group-writable, never world-writable"
grep -q '^reconcile_step_failed()' "$helpers" ||
    fail "the extracted helpers do not include reconcile_step_failed"
grep -Fq 'safe to retry' "$helpers" ||
    fail "permissions reconciliation does not name a retry remedy on failure"

reconcile_line="$(grep -nF 'reconcile_workspace_permissions "$ENV_GITCONFIG"' "$post_create" |
    head -1 | cut -d: -f1)"
lefthook_line="$(grep -n '^    lefthook install$' "$post_create" |
    head -1 | cut -d: -f1)"
[ -n "$reconcile_line" ] && [ -n "$lefthook_line" ] ||
    fail "could not locate reconciliation or lefthook install in $post_create"
[ "$reconcile_line" -lt "$lefthook_line" ] ||
    fail "workspace permissions reconciliation occurs after lefthook install"
! grep -Fq 'reconcile_workspace_ownership' "$post_create" ||
    fail "the old ownership reconciliation name remains"
grep -Fq 'reconcile_workspace_permissions "$ENV_GITCONFIG"' "$post_create" ||
    fail "permissions reconciliation is not called directly"

assert_managed_hook_script() {
    local bot_script="$1"

    grep -Fq 'install_repo_managed_hooks()' "$bot_script" ||
        fail "$bot_script does not define managed hook installation"
    grep -Fq 'cp "$hook" "$target"' "$bot_script" ||
        fail "$bot_script does not copy named managed hooks"
    grep -Fq 'chmod +x "$target"' "$bot_script" ||
        fail "$bot_script does not chmod named managed hooks"
    ! grep -Fq 'chmod +x "$target" || true' "$bot_script" ||
        fail "$bot_script still swallows a chmod +x failure on a managed hook"
    ! grep -Fq 'chmod +x .git/hooks/*' "$bot_script" ||
        fail "$bot_script still chmods every Git sample hook"
    ! grep -Fq 'chmod +x "$hooks_dir"/*' "$bot_script" ||
        fail "$bot_script still chmods a wildcard hook path"
}
assert_managed_hook_script "$bot_post_create"
if [ -f .dogfood-answers.yml ] && [ -d template ]; then
    assert_managed_hook_script "$template_bot_post_create"
fi

managed_helpers="$tmp_root/managed-hooks.sh"
# GNU sed's `{addr!p}` grouping (the previous form here) is rejected by BSD
# sed ("extra characters at the end of p command") — #1337. Print the whole
# range, then drop its last line (the range's own end address) with a second
# pass instead, the same POSIX-portable idiom already used above for the
# workspace-permissions extraction. On macOS, PATH can be shadowed by a
# non-BSD sed (e.g. Homebrew coreutils), which would mask a BSD-only
# regression here, so pin to the real platform sed there; elsewhere stay on
# bare `sed` — this script also ships to generated repos, and not every
# Linux environment keeps sed at /usr/bin/sed (BusyBox, NixOS).
sed_bin=sed
[ "$(uname -s)" != Darwin ] || sed_bin=/usr/bin/sed
"$sed_bin" -n '/^resolve_relative_to()/,/^install_repo_managed_hooks() {$/p' "$bot_post_create" | "$sed_bin" '$d' >"$managed_helpers"
"$sed_bin" -n '/^install_repo_managed_hooks()/,/^}$/p' "$bot_post_create" >>"$managed_helpers"
[ -s "$managed_helpers" ] || fail "could not extract managed hook installer"
grep -q '^resolve_hooks_common_dir()' "$managed_helpers" ||
    fail "the extracted helpers do not include resolve_hooks_common_dir (#1241 integration round 2, Codex finding 4056048551)"
grep -q '^install_repo_managed_hooks()' "$managed_helpers" ||
    fail "the extracted hook installer is missing its function"

fixture="$tmp_root/fixture"
repo="$fixture/workspaces/example"
unrelated="$fixture/unrelated"
home="$fixture/home"
xdg="$fixture/xdg"
exact_xdg="$fixture/exact-xdg"
no_safe_xdg="$fixture/no-safe-xdg"
host_home="$fixture/host-home"
host_xdg="$fixture/host-xdg"
fake_bin="$fixture/bin"
log="$fixture/sudo.log"
mkdir -p "$repo/subdirectory" "$unrelated" "$home" "$xdg/git" "$exact_xdg/git" "$no_safe_xdg/git" "$host_home" "$host_xdg/git" "$fake_bin"
repo="$(cd "$repo" && pwd -P)"
unrelated="$(cd "$unrelated" && pwd -P)"

git -C "$repo" init -q
mkdir -p "$repo/.git/hooks"
printf '%s\n' tracked >"$repo/tracked.txt"
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test add tracked.txt
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test commit -qm init
git -C "$repo" config --file "$xdg/git/config" --add safe.directory '*'
# An unmanaged hook (not one of the repo's own, which install_repo_managed_hooks
# re-chmods separately): permissions repair must preserve its executable bit,
# never strip it, the same way the original capital-X chmod always did.
printf '%s\n' '#!/bin/sh' 'echo unmanaged' >"$repo/.git/hooks/pre-push"
chmod 0755 "$repo/.git/hooks/pre-push"
chmod 0500 "$repo/.git/hooks"
chmod 0700 "$repo/.git"

git_mode() {
    stat -c '%a' "$1" 2>/dev/null && return
    # BSD stat has no equivalent to GNU's %a: %Lp alone drops the
    # setuid/setgid/sticky digit entirely, silently reporting "775" for a
    # setgid 2775 directory (#1337). %Mp%Lp keeps it but always pads a
    # leading "0" when unset, where %a omits it — strip that one leading
    # zero to match.
    local mode
    mode="$(stat -f '%Mp%Lp' "$1")"
    printf '%s\n' "${mode#0}"
}
expected_owner="$(id -u):$(id -g)"
# The fake sudo shim logs its args verbatim, so the ownership reclaim's
# expected log line is the exact `find ... -exec chown ... {} +` invocation
# scoped to directories and single-linked regular files (#1241 review round
# 3, finding F23) — a bare `chown -R` no longer appears anywhere in the log.
expected_chown_log() {
    printf 'find %s ( -type d -o ( -type f -a -links 1 ) ) -exec chown %s {} +' "$1" "$2"
}

# The real post-create script invokes sudo only for the scoped ownership
# reclaim and the setgid pass — both now `sudo find ... -exec ... {} +`
# since F23 (review round 3) scoped them to directories and single-linked
# files (the fixture's invoking user already owns the tree, so reclaiming
# its own uid/gid needs no real privilege); this fixture records the exact
# invocation while letting the command actually run against the fixture's
# own Git metadata. SUDO_FAIL matches against sudo's first argument, which
# is "find" for either privileged step — not "chown"/"chmod" directly.
cat >"$fake_bin/sudo" <<'SUDO'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$SUDO_LOG"
if [ "$SUDO_FAIL" = "$1" ]; then
    exit 1
fi
"$@"
SUDO
chmod 0755 "$fake_bin/sudo"
SUDO_FAIL=""

run_reconcile_at() {
    local target_repo="$1" target_config="$2" target_log="$3"
    (
        cd "$target_repo/subdirectory"
        HOME="$home" XDG_CONFIG_HOME="$xdg" SUDO_LOG="$target_log" SUDO_FAIL="$SUDO_FAIL" PATH="$fake_bin:$PATH" bash -c 'set -e; . "$1"; reconcile_workspace_permissions "$2"; printf "%s\\n" "$RECONCILED_WORKSPACE_ROOT"' _ "$helpers" "$target_config"
    )
}
run_reconcile() {
    run_reconcile_at "$repo" "$xdg/git/config" "$log"
}

echo "==> mismatched-workspace fixture reclaims ownership, preserves the original group, and sets non-world-writable modes"
resolved="$(run_reconcile)"
[ "$resolved" = "$repo" ] ||
    fail "resolved workspace root was '$resolved', expected '$repo'"
grep -Fqx "$(expected_chown_log "$repo/.git" "$expected_owner")" "$log" ||
    fail "Git metadata ownership was not reclaimed (owner) / preserved (group) at the resolved root"
grep -Fqx "find $repo/.git -type d -exec chmod g+s {} +" "$log" ||
    fail "the setgid pass did not run under sudo (#1241 challenge round 5, finding F13)"
! grep -Eq '^(mountpoint|mkdir) ' "$log" ||
    fail "permissions reconciliation ran unexpected commands under sudo"
! grep -Fq "$unrelated" "$log" ||
    fail "permissions reconciliation touched an unrelated path"
# Directories are setgid (leading "2"): rwx for owner+group, r-x for other.
# Files are group-writable but never setgid: rw- for owner+group, r-- for
# other — except a pre-existing executable file, which keeps its exec bit
# in every class (rwx owner+group, r-x other) via capital-X.
[ "$(git_mode "$repo/.git")" = "2775" ] ||
    fail "Git metadata directory is not exactly 2775 (setgid, group-writable) after permissions repair"
[ "$(git_mode "$repo/.git/hooks")" = "2775" ] ||
    fail "Git hooks directory is not exactly 2775 (setgid, group-writable) after permissions repair"
[ "$(git_mode "$repo/.git/config")" = "664" ] ||
    fail "a Git metadata file is not exactly 0664 (group-writable) after permissions repair"
[ -x "$repo/.git/hooks/pre-push" ] ||
    fail "an unmanaged hook's executable bit was stripped by permissions repair"
[ "$(git_mode "$repo/.git/hooks/pre-push")" = "775" ] ||
    fail "an unmanaged hook is not exactly 0775 (group-writable, exec bit preserved, no setgid on a file) after permissions repair"
if find "$repo/.git" -perm -002 | grep . >/dev/null; then
    fail "some Git metadata entry remains world-writable"
fi
[ -r "$repo/.git" ] && [ -w "$repo/.git" ] && [ -x "$repo/.git" ] ||
    fail "Git metadata directory is not readable, writable, and traversable"
[ -r "$repo/.git/hooks" ] && [ -w "$repo/.git/hooks" ] && [ -x "$repo/.git/hooks" ] ||
    fail "Git hooks directory is not writable after permissions repair"

host_status="$(GIT_CONFIG_NOSYSTEM=1 HOME="$host_home" XDG_CONFIG_HOME="$host_xdg" git -C "$repo" status --short)"
[ -z "$host_status" ] ||
    fail "host-side Git was not usable after container setup: $host_status"

echo "==> a commit made AFTER reconciliation still produces group-writable, never world-writable, Git metadata (#1241 challenge round 2, finding F5)"
[ "$(git -C "$repo" config core.sharedRepository)" = "0664" ] ||
    fail "reconciliation did not configure an explicit, umask-independent core.sharedRepository"
# Force a permissive umask for this one check: the symbolic
# core.sharedRepository=group value only raises the GROUP class to match
# the owner, leaving "other" governed by umask — a real regression this
# fixture caught under this environment's own ambient umask (000). Forcing
# it explicitly makes the case deterministic regardless of the umask the
# CALLING environment happens to have, rather than depending on it.
(
    umask 000
    # A directory's mtime bumps whenever ANY child changes (e.g. index/
    # COMMIT_EDITMSG rewrites touch .git itself), so "-newer" over-matches
    # pre-existing directories. Diff the directory LISTING instead to
    # isolate genuinely new paths — object fanout directories a fresh
    # blob/tree/commit needs that did not exist before.
    dirs_before="$(find "$repo/.git" -type d | sort)"
    repo_branch="$(git -C "$repo" symbolic-ref --short HEAD)"
    printf '%s\n' second >"$repo/second.txt"
    git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test add second.txt
    git -C "$repo" -c user.name=fixture -c user.email=fixture@example.test commit -qm "second (post-reconciliation)"
    dirs_after="$(find "$repo/.git" -type d | sort)"
    new_dirs="$(comm -13 <(printf '%s\n' "$dirs_before") <(printf '%s\n' "$dirs_after"))"
    [ -n "$new_dirs" ] ||
        fail "fixture setup: the post-reconciliation commit did not create any new Git directory to check"
    printf '%s\n' "$new_dirs" | while IFS= read -r new_dir; do
        [ "$(git_mode "$new_dir")" = "2775" ] ||
            fail "a directory ($new_dir) created by a post-reconciliation commit under a permissive umask is not exactly group-writable/setgid (core.sharedRepository regression — world-writable or umask-dependent)"
    done
    [ "$(git_mode "$repo/.git/refs/heads/$repo_branch")" = "664" ] ||
        fail "the branch ref rewritten by a post-reconciliation commit under a permissive umask is not exactly group-writable"
)

cat >"$fake_bin/lefthook" <<'LEFTHOOK'
#!/bin/sh
set -eu
[ "$1" = install ]
printf '%s\n' installed >"$LETHOOK_TARGET"
LEFTHOOK
chmod 0755 "$fake_bin/lefthook"
(
    cd "$repo"
    LETHOOK_TARGET="$repo/.git/hooks/pre-commit" PATH="$fake_bin:$PATH" lefthook install
)
[ -f "$repo/.git/hooks/pre-commit" ] ||
    fail "a Lefthook hook could not be written after permissions repair"

echo "==> the ORIGINAL group survives reconciliation, distinct from the invoking process's primary gid (#1241 challenge round 1, finding F1)"
# A single-user sandbox can't create a real UID mismatch, but a distinct
# SECONDARY group id proves the same thing this fix depends on: the group is
# read from the tree at reconciliation time, not defaulted to whatever the
# reconciling process's own primary gid happens to be.
#
# In a user-namespaced or id-mapped container, `id -G` can list an overflow
# supplementary gid (e.g. 65534) the mounted filesystem cannot actually
# assign — chgrp to it fails, and under this script's `set -e` that would
# abort the whole suite rather than the one fixture. Probe each candidate
# with a scratch chgrp first and use only one that is actually assignable
# here; skip the fixture with a reason rather than failing if none is
# (#1241 challenge round 3, finding F7).
gid_probe_target="$fixture/gid-probe-target"
secondary_gid=""
for candidate_gid in $(id -G | tr ' ' '\n' | grep -vx "$(id -g)"); do
    : >"$gid_probe_target"
    if chgrp "$candidate_gid" "$gid_probe_target" 2>/dev/null; then
        secondary_gid="$candidate_gid"
        break
    fi
done
rm -f "$gid_probe_target"
if [ -n "$secondary_gid" ]; then
    gid_repo="$fixture/workspaces/gid-example"
    gid_config="$fixture/gid-xdg/git/config"
    gid_log="$fixture/gid-sudo.log"
    mkdir -p "$gid_repo/subdirectory" "$fixture/gid-xdg/git"
    # Resolve to the physical path, matching $repo/$unrelated above: on
    # macOS $TMPDIR sits under /var, itself a symlink to /private/var, and
    # reconcile_workspace_permissions resolves its own workspace_root via
    # `pwd -P` — an unresolved expected value here would never match it
    # (#1337).
    gid_repo="$(cd "$gid_repo" && pwd -P)"
    git -C "$gid_repo" init -q
    chgrp "$secondary_gid" "$gid_repo/.git"
    [ "$(stat -c '%g' "$gid_repo/.git" 2>/dev/null || stat -f '%g' "$gid_repo/.git")" = "$secondary_gid" ] ||
        fail "fixture setup: could not set the Git directory's group to $secondary_gid"
    gid_resolved="$(run_reconcile_at "$gid_repo" "$gid_config" "$gid_log")"
    [ "$gid_resolved" = "$gid_repo" ] ||
        fail "gid-preservation resolved workspace root was '$gid_resolved', expected '$gid_repo'"
    grep -Fqx "$(expected_chown_log "$gid_repo/.git" "$(id -u):${secondary_gid}")" "$gid_log" ||
        fail "reconciliation did not preserve the original (non-primary) group when reclaiming ownership"
    [ "$(stat -c '%g' "$gid_repo/.git" 2>/dev/null || stat -f '%g' "$gid_repo/.git")" = "$secondary_gid" ] ||
        fail "reconciliation changed the group away from the original (non-primary) one"
else
    echo "  (skipped: no secondary group available that is both distinct from the primary gid and actually assignable here)"
fi

echo "==> setgid survives reconciliation even when the invoking user is NOT a member of the preserved group (#1241 challenge round 5, finding F13)"
# The fixture above only ever proves preservation for a gid the invoking
# user already belongs to — the realistic UID-mismatch case is a host
# group the container user has no reason to be a member of, and Linux
# silently drops S_ISGID (while chmod still reports success) unless the
# caller is either a member or privileged. This needs a REAL sudo, not the
# logging shim: the shim never grants actual privilege, so it could not
# tell a privileged setgid pass from an unprivileged one that got silently
# dropped. Constructing the fixture itself also needs real sudo (chgrp to
# a group the invoking user does not belong to is exactly as restricted).
nonmember_gid=""
for candidate_gid in $(getent group | awk -F: '{print $3}'); do
    case " $(id -G) " in
    *" $candidate_gid "*) continue ;;
    esac
    nonmember_gid="$candidate_gid"
    break
done
if [ -n "$nonmember_gid" ] && sudo -n true 2>/dev/null; then
    nonmember_repo="$fixture/workspaces/nonmember-gid"
    nonmember_xdg="$fixture/nonmember-xdg"
    mkdir -p "$nonmember_repo/subdirectory" "$nonmember_xdg/git"
    git -C "$nonmember_repo" init -q
    sudo chgrp "$nonmember_gid" "$nonmember_repo/.git"
    [ "$(stat -c '%g' "$nonmember_repo/.git" 2>/dev/null || stat -f '%g' "$nonmember_repo/.git")" = "$nonmember_gid" ] ||
        fail "fixture setup: could not set the Git directory's group to the non-member gid $nonmember_gid"
    (
        cd "$nonmember_repo/subdirectory"
        HOME="$home" XDG_CONFIG_HOME="$nonmember_xdg" \
            bash -c 'set -e; . "$1"; reconcile_workspace_permissions "$2"' _ "$helpers" "$nonmember_xdg/git/config"
    ) || fail "reconciliation failed against a non-member-gid fixture"
    [ "$(git_mode "$nonmember_repo/.git")" = "2775" ] ||
        fail "setgid did not survive reconciliation when the container user is not a member of the preserved group (#1241 challenge round 5, finding F13 regression)"
    [ "$(stat -c '%g' "$nonmember_repo/.git" 2>/dev/null || stat -f '%g' "$nonmember_repo/.git")" = "$nonmember_gid" ] ||
        fail "the non-member group was not preserved by reconciliation"
else
    echo "  (skipped: no non-member gid and/or passwordless sudo available to exercise this with)"
fi

echo "==> reconciling a locally-cloned checkout never mutates the source repository's hard-linked objects (#1241 review round 3, finding F23)"
f23_source="$fixture/f23-source"
f23_clone="$fixture/workspaces/f23-clone"
f23_xdg="$fixture/f23-xdg/git/config"
f23_log="$fixture/f23-sudo.log"
mkdir -p "$f23_source" "$fixture/f23-xdg/git"
git -C "$f23_source" init -q
printf '%s\n' tracked >"$f23_source/file.txt"
git -C "$f23_source" -c user.name=fixture -c user.email=fixture@example.test add file.txt
git -C "$f23_source" -c user.name=fixture -c user.email=fixture@example.test commit -qm init
# `git clone --local` (the default when the source is a local path) hard-links
# loose objects into the clone instead of copying them — verified below by
# comparing inodes, not assumed.
git clone -q --local "$f23_source" "$f23_clone"
mkdir -p "$f23_clone/subdirectory"
f23_object="$(find "$f23_source/.git/objects" -type f | sort | head -1)"
[ -n "$f23_object" ] || fail "fixture setup: source repo has no loose objects to test with"
f23_object_relative="${f23_object#"$f23_source"/}"
f23_clone_object="$f23_clone/$f23_object_relative"
[ "$(stat -c '%i' "$f23_object")" = "$(stat -c '%i' "$f23_clone_object")" ] ||
    fail "fixture setup: git clone --local did not hard-link objects (same inode expected) — cannot exercise F23 without this"
f23_before="$(stat -c '%u:%g:%a' "$f23_object")"
f23_resolved="$(run_reconcile_at "$f23_clone" "$f23_xdg" "$f23_log")"
[ "$f23_resolved" = "$f23_clone" ] ||
    fail "reconciliation of a locally-cloned checkout did not resolve its own workspace root (resolved '$f23_resolved', expected '$f23_clone')"
f23_after="$(stat -c '%u:%g:%a' "$f23_object")"
[ "$f23_before" = "$f23_after" ] ||
    fail "reconciling the clone changed the SOURCE repository's hard-linked object (before='$f23_before' after='$f23_after') — an out-of-scope mutation outside \$git_dir"
# The reconciliation must still do its job on the clone's own, non-hard-linked
# files — F23's fix narrows scope, it must not silently no-op the whole step.
grep -Fqx "$(expected_chown_log "$f23_clone/.git" "$expected_owner")" "$f23_log" ||
    fail "reconciliation did not scope ownership reclaim to directories and single-linked files against the clone's own .git"
[ "$(git_mode "$f23_clone/.git/HEAD")" = "664" ] ||
    fail "reconciliation did not grant group-write on the clone's own (non-hard-linked) HEAD file"
[ "$(git_mode "$f23_clone/.git")" = "2775" ] ||
    fail "reconciliation did not set the clone's own .git directory mode/setgid"

echo "==> reconciliation breaks the hard link for a multi-linked object the container user cannot read, without mutating the source (#1241 integration round 2, Codex finding 4056048549)"
# Needs REAL sudo (not the logging shim above): the whole point is that only
# a privileged process can read a mode-0000 object to copy it. Skip
# gracefully, like the F13 non-member-gid fixture, if this environment has
# no passwordless sudo — and skip when the invoking user IS root: chmod 0000
# below cannot make anything unreadable to uid 0 (root bypasses discretionary
# permission checks on regular-file reads), so this fixture's own setup
# assertion would fail as a false alarm, not a real regression (#1241
# integration round 3, Codex finding 4056166570).
if [ "$(id -u)" -ne 0 ] && sudo -n true 2>/dev/null; then
    f2_source="$fixture/f2-source"
    f2_clone="$fixture/workspaces/f2-clone"
    f2_xdg="$fixture/f2-xdg/git/config"
    mkdir -p "$f2_source" "$fixture/f2-xdg/git"
    (
        umask 027
        git -C "$f2_source" init -q
        printf '%s\n' tracked >"$f2_source/file.txt"
        git -C "$f2_source" -c user.name=fixture -c user.email=fixture@example.test add file.txt
        git -C "$f2_source" -c user.name=fixture -c user.email=fixture@example.test commit -qm init
        git clone -q --local "$f2_source" "$f2_clone"
    )
    mkdir -p "$f2_clone/subdirectory"
    f2_object="$(find "$f2_source/.git/objects" -type f | sort | head -1)"
    [ -n "$f2_object" ] || fail "fixture setup: source repo has no loose objects to test with"
    f2_object_relative="${f2_object#"$f2_source"/}"
    f2_clone_object="$f2_clone/$f2_object_relative"
    [ "$(stat -c '%i' "$f2_object")" = "$(stat -c '%i' "$f2_clone_object")" ] ||
        fail "fixture setup: git clone --local did not hard-link objects — cannot exercise this finding without it"
    # Simulate the real-world gap directly: a restrictive host-side umask at
    # clone time can leave a hard-linked object unreadable to a different
    # container uid/gid. This environment cannot fake a different uid, so
    # mode 0000 removes even the invoking user's own read access — real
    # sudo can still read it; the unprivileged reconciliation cannot,
    # exactly like the gap this fixture proves closed.
    chmod 0000 "$f2_object"
    [ ! -r "$f2_object" ] || fail "fixture setup: object is still readable to the invoking user, cannot exercise this finding"
    f2_source_inode_before="$(stat -c '%i' "$f2_object")"
    # REAL sudo, not the logging shim above (same reasoning as the F13
    # non-member-gid fixture): breaking the hard link needs genuine
    # privilege to read a mode-0000 object, which the shim's unprivileged
    # exec cannot grant.
    f2_resolved="$(
        cd "$f2_clone/subdirectory"
        HOME="$home" XDG_CONFIG_HOME="$xdg" \
            bash -c 'set -e; . "$1"; reconcile_workspace_permissions "$2"; printf "%s\n" "$RECONCILED_WORKSPACE_ROOT"' _ "$helpers" "$f2_xdg"
    )" || fail "reconciliation failed against the umask-027 hard-linked-object fixture"
    [ "$f2_resolved" = "$f2_clone" ] ||
        fail "reconciliation of the umask-027 clone did not resolve its own workspace root (resolved '$f2_resolved', expected '$f2_clone')"
    [ "$(stat -c '%i' "$f2_object")" = "$f2_source_inode_before" ] ||
        fail "breaking the hard link changed the SOURCE repository's object inode — the shared object outside \$git_dir must never be mutated"
    [ ! -r "$f2_object" ] ||
        fail "the SOURCE repository's object became readable — its mode must be untouched, only the clone's own copy is fixed"
    [ "$(stat -c '%i' "$f2_clone_object")" != "$f2_source_inode_before" ] ||
        fail "the clone's object is still hard-linked to the source after reconciliation — the link was never broken"
    [ -r "$f2_clone_object" ] ||
        fail "the clone's own copy of the object is still unreadable to the container user after reconciliation"
    [ "$(git_mode "$f2_clone_object")" = "664" ] ||
        fail "the clone's own (now single-linked) copy was not reconciled to this workspace's target mode"
else
    echo "  (skipped: running as root, and/or no passwordless sudo available to exercise this with)"
fi

echo "==> reconciliation un-links a multi-linked file OUTSIDE objects/ unconditionally, never mutating what it was shared with (#1241 integration round 3, Codex finding 4056166568)"
hook_hl_repo="$fixture/workspaces/hook-hl-repo"
hook_hl_shared="$fixture/hook-hl-shared-source"
hook_hl_xdg="$fixture/hook-hl-xdg/git/config"
hook_hl_log="$fixture/hook-hl-sudo.log"
mkdir -p "$hook_hl_repo/subdirectory" "$fixture/hook-hl-xdg/git"
git -C "$hook_hl_repo" init -q
# A hard link on a MUTABLE, non-objects path — e.g. a user's own shared
# hook-management setup linking .git/hooks/pre-commit to a file elsewhere —
# is exactly the shape the objects/-only exemption must NOT also cover.
printf '%s\n' '#!/bin/sh' 'echo pre-existing-shared-hook' >"$hook_hl_shared"
chmod 0644 "$hook_hl_shared"
ln "$hook_hl_shared" "$hook_hl_repo/.git/hooks/pre-commit"
[ "$(stat -c '%i' "$hook_hl_shared")" = "$(stat -c '%i' "$hook_hl_repo/.git/hooks/pre-commit")" ] ||
    fail "fixture setup: pre-commit was not hard-linked to the shared source"
hook_hl_shared_inode_before="$(stat -c '%i' "$hook_hl_shared")"
hook_hl_shared_mode_before="$(stat -c '%a' "$hook_hl_shared")"
hook_hl_resolved="$(run_reconcile_at "$hook_hl_repo" "$hook_hl_xdg" "$hook_hl_log")"
[ "$hook_hl_resolved" = "$hook_hl_repo" ] ||
    fail "reconciliation of the hard-linked-hook fixture did not resolve its own workspace root (resolved '$hook_hl_resolved', expected '$hook_hl_repo')"
[ "$(stat -c '%i' "$hook_hl_shared")" = "$hook_hl_shared_inode_before" ] ||
    fail "un-linking the repo's hook changed the SHARED source's inode — it must never be mutated"
[ "$(stat -c '%a' "$hook_hl_shared")" = "$hook_hl_shared_mode_before" ] ||
    fail "un-linking the repo's hook changed the SHARED source's mode — it must never be mutated"
[ "$(stat -c '%i' "$hook_hl_repo/.git/hooks/pre-commit")" != "$hook_hl_shared_inode_before" ] ||
    fail "the repo's own hooks/pre-commit is still hard-linked to the shared source after reconciliation — the objects/-only exemption leaked outside objects/"
[ "$(git_mode "$hook_hl_repo/.git/hooks/pre-commit")" = "664" ] ||
    fail "the repo's own (now single-linked) hooks/pre-commit was not reconciled to this workspace's target mode"
grep -Fqx 'echo pre-existing-shared-hook' "$hook_hl_repo/.git/hooks/pre-commit" ||
    fail "un-linking the repo's hook did not preserve its content"
# The actual regression this closes: install_repo_managed_hooks's own `cp`
# must now succeed against the (formerly hard-linked, now reconciled) path.
mkdir -p "$hook_hl_repo/.devcontainer/hooks"
printf '%s\n' '#!/bin/sh' 'echo managed-now' >"$hook_hl_repo/.devcontainer/hooks/pre-commit"
chmod 0644 "$hook_hl_repo/.devcontainer/hooks/pre-commit"
(
    cd "$hook_hl_repo"
    . "$managed_helpers"
    install_repo_managed_hooks
) || fail "install_repo_managed_hooks still fails against a hook path that was hard-linked before reconciliation"
grep -Fqx 'echo managed-now' "$hook_hl_repo/.git/hooks/pre-commit" ||
    fail "install_repo_managed_hooks did not actually install the managed hook after reconciliation un-linked the path"

echo "==> the privileged un-link copy refuses a target swapped to a symlink between enumeration and copy, never dereferencing it (#1241 integration round 4, Codex finding 4056318550)"
# A genuine multi-process race (something swaps the path between find's
# enumeration and the privileged copy) cannot be staged deterministically
# and portably in this fixture. Instead, extract the exact privileged
# inline script from the production file by its own markers — so this
# stays attached to the real implementation rather than a hand-copied
# duplicate that could silently drift — and drive it directly with a
# controlled precondition: a candidate whose inode was captured (as find
# would), then swapped to a symlink before the script runs against that
# now-stale captured inode. No real privilege is needed for either case
# below: the property under test is that the swap is DETECTED and
# refused, which happens before any read of the swapped-to content is
# even attempted.
priv_start_line="$(grep -n "^        sudo sh -c '\$" "$post_create" | head -1 | cut -d: -f1)"
priv_end_line="$(grep -n '^        . _ "\$linked_object"' "$post_create" | head -1 | cut -d: -f1)"
[ -n "$priv_start_line" ] && [ -n "$priv_end_line" ] ||
    fail "could not locate the privileged un-link script's markers in $post_create"
priv_script="$tmp_root/priv-unlink.sh"
sed -n "$((priv_start_line + 1)),$((priv_end_line - 1))p" "$post_create" >"$priv_script"
[ -s "$priv_script" ] || fail "extracted an empty privileged un-link script"
grep -Fq 'cp -Pp' "$priv_script" ||
    fail "the extracted privileged script does not use a no-dereference copy (#1241 integration round 4, Codex finding 4056318550)"
grep -Fq 'current_inode' "$priv_script" ||
    fail "the extracted privileged script does not compare the captured inode before copying"

priv_repo="$tmp_root/priv-unlink-repo"
priv_decoy="$tmp_root/priv-unlink-decoy"
mkdir -p "$priv_repo"
printf 'original content\n' >"$priv_repo/candidate"
priv_seen_inode="$(stat -c '%i' "$priv_repo/candidate" 2>/dev/null || stat -f '%i' "$priv_repo/candidate")"
printf 'DECOY-must-never-appear-in-workspace\n' >"$priv_decoy"
rm -f "$priv_repo/candidate"
ln -s "$priv_decoy" "$priv_repo/candidate"
if sh "$priv_script" "$priv_repo/candidate" "$(id -u):$(id -g)" "$priv_seen_inode" 2>/dev/null; then
    fail "the privileged un-link script accepted a target that was swapped to a symlink with a stale captured inode"
fi
[ -L "$priv_repo/candidate" ] ||
    fail "the swapped symlink was replaced instead of being left alone after refusing"
if [ ! -L "$priv_repo/candidate" ] && grep -q DECOY "$priv_repo/candidate" 2>/dev/null; then
    fail "the decoy content was copied into the workspace as a plain file — the swapped symlink was dereferenced"
fi
[ -z "$(find "$tmp_root" -maxdepth 1 -name '.harmon-init-unlink.*' -print -quit)" ] ||
    fail "a leftover .harmon-init-unlink.* temp file was left behind after refusing"

# Hardening a real attack path must never break the genuine, unmodified
# candidate this whole mechanism exists to reconcile.
priv_repo2="$tmp_root/priv-unlink-repo2"
mkdir -p "$priv_repo2"
printf 'original content\n' >"$priv_repo2/candidate"
priv_seen_inode2="$(stat -c '%i' "$priv_repo2/candidate" 2>/dev/null || stat -f '%i' "$priv_repo2/candidate")"
sh "$priv_script" "$priv_repo2/candidate" "$(id -u):$(id -g)" "$priv_seen_inode2" ||
    fail "the privileged un-link script refused a genuine, unmodified candidate"
[ "$(cat "$priv_repo2/candidate")" = "original content" ] ||
    fail "the privileged un-link script did not preserve content for a genuine candidate"
[ "$(git_mode "$priv_repo2/candidate")" = "664" ] ||
    fail "the privileged un-link script did not reconcile mode for a genuine candidate"

echo "==> exact safe.directory is added beside, not instead of, a wildcard"
safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$xdg" git config --file "$xdg/git/config" --get-all safe.directory)"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc "$repo")" -eq 1 ] ||
    fail "the exact workspace safe.directory entry is missing or duplicated: $safe_entries"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc '*')" -eq 1 ] ||
    fail "the pre-existing wildcard safe.directory entry was unexpectedly rewritten"
actual_root="$(GIT_CONFIG_NOSYSTEM=1 HOME="$home" XDG_CONFIG_HOME="$xdg" git -C "$repo" rev-parse --path-format=absolute --show-toplevel)"
[ "$actual_root" = "$repo" ] ||
    fail "Git did not inspect the exact safe workspace: $actual_root"

echo "==> exact safe.directory is effective without a wildcard"
run_reconcile_at "$repo" "$exact_xdg/git/config" "$fixture/exact-sudo.log" >/dev/null
safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$exact_xdg" git config --file "$exact_xdg/git/config" --get-all safe.directory)"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc "$repo")" -eq 1 ] ||
    fail "the exact-only safe.directory entry is missing or duplicated: $safe_entries"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc '*')" -eq 0 ] ||
    fail "the exact-only safe.directory config unexpectedly contains a wildcard"
if GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 HOME="$home" XDG_CONFIG_HOME="$no_safe_xdg" git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
    fail "Git accepted the ownership-mismatched fixture without safe.directory"
fi
actual_root="$(GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 HOME="$home" XDG_CONFIG_HOME="$exact_xdg" git -C "$repo" rev-parse --path-format=absolute --show-toplevel)" ||
    fail "Git rejected the exact safe.directory entry for the ownership-mismatched fixture"
[ "$actual_root" = "$repo" ] ||
    fail "Git did not inspect the exact-only safe workspace: $actual_root"

echo "==> repeated permissions reconciliation is idempotent"
: >"$log"
run_reconcile >/dev/null
safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$xdg" git config --file "$xdg/git/config" --get-all safe.directory)"
[ "$(printf '%s\n' "$safe_entries" | grep -Fxc "$repo")" -eq 1 ] ||
    fail "repeated reconciliation duplicated safe.directory: $safe_entries"
grep -Fqx "$(expected_chown_log "$repo/.git" "$expected_owner")" "$log" ||
    fail "repeated reconciliation did not re-assert ownership"
[ "$(git_mode "$repo/.git")" = "2775" ] ||
    fail "repeated reconciliation changed the Git metadata directory mode"

echo "==> linked-worktree fixture reconciles the real common directory, not the .git pointer file (#1241 item 6)"
wt_main="$fixture/workspaces/wt-main"
wt_linked="$fixture/workspaces/wt-linked"
wt_xdg="$fixture/wt-xdg/git/config"
wt_log="$fixture/wt-sudo.log"
mkdir -p "$wt_main" "$fixture/wt-xdg/git"
wt_main="$(cd "$wt_main" && pwd -P)"
git -C "$wt_main" init -q
git -C "$wt_main" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm init
git -C "$wt_main" worktree add -q "$wt_linked" -b wt-fixture-branch
wt_linked="$(cd "$wt_linked" && pwd -P)"
mkdir -p "$wt_linked/subdirectory"
[ -f "$wt_linked/.git" ] && [ ! -d "$wt_linked/.git" ] ||
    fail "fixture setup: expected the linked worktree's .git to be a file, not a directory"
wt_admin_name="$(basename "$wt_linked")"
[ -d "$wt_main/.git/worktrees/$wt_admin_name" ] ||
    fail "fixture setup: expected a worktree admin directory at $wt_main/.git/worktrees/$wt_admin_name"

resolved="$(run_reconcile_at "$wt_linked" "$wt_xdg" "$wt_log")"
[ "$resolved" = "$wt_linked" ] ||
    fail "linked-worktree resolved workspace root was '$resolved', expected '$wt_linked'"
grep -Fqx "$(expected_chown_log "$wt_main/.git" "$expected_owner")" "$wt_log" ||
    fail "linked-worktree reconciliation did not reclaim ownership of the MAIN checkout's common Git directory"
! grep -Fq "$wt_linked/.git " "$wt_log" ||
    fail "linked-worktree reconciliation targeted the worktree's .git POINTER FILE instead of the resolved common directory"
[ "$(git_mode "$wt_main/.git")" = "2775" ] ||
    fail "linked-worktree reconciliation did not set the common directory's mode"
[ "$(git_mode "$wt_main/.git/worktrees/$wt_admin_name")" = "2775" ] ||
    fail "linked-worktree reconciliation did not reach the worktree's own private admin directory"
if find "$wt_main/.git" -perm -002 | grep . >/dev/null; then
    fail "linked-worktree reconciliation left some common-directory entry world-writable"
fi
wt_safe_entries="$(HOME="$home" XDG_CONFIG_HOME="$fixture/wt-xdg" git config --file "$wt_xdg" --get-all safe.directory)"
[ "$(printf '%s\n' "$wt_safe_entries" | grep -Fxc "$wt_linked")" -eq 1 ] ||
    fail "linked-worktree safe.directory entry does not name the worktree root: $wt_safe_entries"
wt_host_status="$(GIT_CONFIG_NOSYSTEM=1 HOME="$host_home" XDG_CONFIG_HOME="$host_xdg" git -C "$wt_linked" status --short)"
[ -z "$wt_host_status" ] ||
    fail "host-side Git was not usable in the linked worktree after container setup: $wt_host_status"

echo "==> resolve_git_dir never mutates a .git pointer redirected at an unrelated repository, even though the identical shape is now skipped rather than hard-refused (#1241 challenge round 6 / review round 2, findings F17/F22)"
crafted_victim="$fixture/workspaces/crafted-victim"
crafted_attacker="$fixture/workspaces/crafted-attacker"
crafted_xdg="$fixture/crafted-xdg/git/config"
crafted_log="$fixture/crafted-sudo.log"
mkdir -p "$crafted_victim" "$crafted_attacker/subdirectory" "$fixture/crafted-xdg/git"
git -C "$crafted_victim" init -q
crafted_victim="$(cd "$crafted_victim" && pwd -P)"
victim_listing_before="$(find "$crafted_victim/.git" | sort)"
# A stale/crafted .git FILE naming a real, unrelated repository directly —
# not a genuine worktree admin dir — carries no "gitdir" reverse pointer of
# its OWN and is therefore indistinguishable, at the Git-metadata level,
# from a legitimate submodule or --separate-git-dir checkout (F22): both
# resolve --git-dir and --git-common-dir to the identical directory. The
# maintainer's ruling ("made non-fatal") accepts that this one shape can no
# longer be told apart and made a deliberate trade: privileged mutation is
# refused unconditionally for it (never chown/chmod an admin dir that isn't
# a validated worktrees/ child), while post-create itself no longer aborts.
# What this fixture proves is the security property that survives that
# trade — the crafted redirect never gets privileged access to the
# unrelated victim — not that the pointer is rejected outright.
printf 'gitdir: %s\n' "${crafted_victim}/.git" >"$crafted_attacker/.git"
crafted_resolved="$(run_reconcile_at "$crafted_attacker" "$crafted_xdg" "$crafted_log" 2>"$tmp_root/crafted.err")" ||
    fail "reconciliation aborted post-create for a same-shape .git redirect instead of skipping the privileged mutation (F22)"
[ "$crafted_resolved" = "$crafted_attacker" ] ||
    fail "the skipped workspace was not resolved as its own root (resolved '$crafted_resolved', expected '$crafted_attacker')"
grep -Fq "non-worktree indirection" "$tmp_root/crafted.err" ||
    fail "reconciliation did not explain why the crafted redirect's privileged reconciliation was skipped"
[ ! -e "$crafted_log" ] || [ ! -s "$crafted_log" ] ||
    fail "reconciliation invoked sudo against the crafted pointer — the F17 attack's privileged mutation must still never fire"
victim_listing_after="$(find "$crafted_victim/.git" | sort)"
[ "$victim_listing_before" = "$victim_listing_after" ] ||
    fail "the unrelated victim repository's Git directory contents changed"
crafted_safe_entries="$(git config --file "$crafted_xdg" --get-all safe.directory 2>/dev/null || true)"
grep -Fqx "$crafted_attacker" <<<"$crafted_safe_entries" ||
    fail "a skipped workspace was not trusted via safe.directory so post-create can still proceed"

echo "==> resolve_git_dir refuses a crafted admin dir whose commondir redirects to an unrelated repository (#1241 review round 1, finding F19)"
f19_victim="$fixture/workspaces/f19-victim"
f19_attacker="$fixture/workspaces/f19-attacker"
f19_fake_admin="$fixture/f19-fake-admin"
f19_xdg="$fixture/f19-xdg/git/config"
f19_log="$fixture/f19-sudo.log"
mkdir -p "$f19_victim" "$f19_attacker/subdirectory" "$f19_fake_admin" "$fixture/f19-xdg/git"
git -C "$f19_victim" init -q
f19_victim="$(cd "$f19_victim" && pwd -P)"
f19_victim_listing_before="$(find "$f19_victim/.git" | sort)"
mkdir -p "$f19_attacker/subdirectory"
f19_attacker="$(cd "$f19_attacker" && pwd -P)"
# The fake admin dir's OWN reverse pointer correctly names the attacker's
# .git file (satisfies the round-trip check alone) — but its "commondir"
# names the unrelated victim repository instead of a real common dir. A
# minimal HEAD file is required for Git to recognize the directory as a
# Git dir at all.
printf 'gitdir: %s/.git\n' "$f19_attacker" >"$f19_fake_admin/gitdir"
printf '%s\n' "$f19_victim/.git" >"$f19_fake_admin/commondir"
printf 'ref: refs/heads/main\n' >"$f19_fake_admin/HEAD"
printf 'gitdir: %s\n' "$f19_fake_admin" >"$f19_attacker/.git"
if run_reconcile_at "$f19_attacker" "$f19_xdg" "$f19_log" >/dev/null 2>"$tmp_root/f19.err"; then
    fail "reconciliation accepted a crafted admin dir whose commondir redirects to an unrelated repository"
fi
grep -Fq "not a direct worktrees/ child" "$tmp_root/f19.err" ||
    fail "reconciliation did not name the admin-dir/common-dir relationship refusal"
[ ! -e "$f19_log" ] || [ ! -s "$f19_log" ] ||
    fail "reconciliation invoked sudo against the crafted commondir before refusing it"
f19_victim_listing_after="$(find "$f19_victim/.git" | sort)"
[ "$f19_victim_listing_before" = "$f19_victim_listing_after" ] ||
    fail "the unrelated victim repository's Git directory contents changed"

echo "==> resolve_git_dir accepts a legitimate --relative-paths worktree (#1241 review round 1, finding F21)"
f21_main="$fixture/workspaces/f21-main"
f21_linked="$fixture/workspaces/f21-linked"
f21_xdg="$fixture/f21-xdg/git/config"
f21_log="$fixture/f21-sudo.log"
mkdir -p "$f21_main" "$fixture/f21-xdg/git"
git -C "$f21_main" init -q
git -C "$f21_main" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm init
f21_main="$(cd "$f21_main" && pwd -P)"
if ! git -C "$f21_main" worktree add --relative-paths -q "$f21_linked" -b f21-branch 2>"$tmp_root/f21-setup.err"; then
    echo "  (skipped: this Git version does not support --relative-paths)"
else
    f21_linked="$(cd "$f21_linked" && pwd -P)"
    mkdir -p "$f21_linked/subdirectory"
    case "$(cat "$f21_linked/.git")" in
    "gitdir: ../"*) : ;;
    *) fail "fixture setup: expected a relative gitdir pointer in the --relative-paths worktree" ;;
    esac
    f21_resolved="$(run_reconcile_at "$f21_linked" "$f21_xdg" "$f21_log")"
    [ "$f21_resolved" = "$f21_linked" ] ||
        fail "a legitimate --relative-paths worktree was not accepted (resolved '$f21_resolved', expected '$f21_linked')"
    grep -Fqx "$(expected_chown_log "$f21_main/.git" "$expected_owner")" "$f21_log" ||
        fail "reconciliation did not reach the common directory for a --relative-paths worktree"
fi

echo "==> resolve_git_dir skips privileged reconciliation for a genuine --separate-git-dir checkout, without aborting post-create (#1241 review round 2, finding F22)"
f22_repo="$fixture/workspaces/f22-repo"
f22_gitdir="$fixture/f22-external-gitdir"
f22_xdg="$fixture/f22-xdg/git/config"
f22_log="$fixture/f22-sudo.log"
mkdir -p "$f22_repo/subdirectory" "$fixture/f22-xdg/git"
git init -q --separate-git-dir="$f22_gitdir" "$f22_repo"
f22_repo="$(cd "$f22_repo" && pwd -P)"
f22_gitdir="$(cd "$f22_gitdir" && pwd -P)"
f22_gitdir_listing_before="$(find "$f22_gitdir" | sort)"
f22_resolved="$(run_reconcile_at "$f22_repo" "$f22_xdg" "$f22_log" 2>"$tmp_root/f22.err")" ||
    fail "reconciliation aborted post-create for a genuine --separate-git-dir checkout instead of skipping it"
[ "$f22_resolved" = "$f22_repo" ] ||
    fail "a --separate-git-dir checkout was not resolved as its own workspace root (resolved '$f22_resolved', expected '$f22_repo')"
grep -Fq "non-worktree indirection" "$tmp_root/f22.err" ||
    fail "reconciliation did not explain why privileged reconciliation was skipped for the --separate-git-dir checkout"
[ ! -e "$f22_log" ] || [ ! -s "$f22_log" ] ||
    fail "reconciliation invoked sudo against a --separate-git-dir checkout it should only skip"
f22_gitdir_listing_after="$(find "$f22_gitdir" | sort)"
[ "$f22_gitdir_listing_before" = "$f22_gitdir_listing_after" ] ||
    fail "the external --separate-git-dir directory's contents changed despite being skipped, not mutated"
f22_safe_entries="$(git config --file "$f22_xdg" --get-all safe.directory 2>/dev/null || true)"
grep -Fqx "$f22_repo" <<<"$f22_safe_entries" ||
    fail "a skipped --separate-git-dir checkout was not trusted via safe.directory so post-create can still proceed"

echo "==> resolve_git_dir treats a .git DIRECTORY containing its own commondir file as unverifiable indirection, never trusting it directly (#1241 integration round 3, Codex finding 4056166565)"
cd_repo="$fixture/workspaces/cd-repo"
cd_victim="$fixture/cd-victim-common"
cd_xdg="$fixture/cd-xdg/git/config"
cd_log="$fixture/cd-sudo.log"
mkdir -p "$cd_repo/.git" "$cd_repo/subdirectory" "$cd_victim" "$fixture/cd-xdg/git"
git -C "$cd_victim" init -q
cd_victim="$(cd "$cd_victim" && pwd -P)"
# A .git DIRECTORY (not a file) that additionally carries its own
# "commondir" — the same marker a worktree admin dir uses — is indirection
# Git itself follows via --git-common-dir, not an ordinary checkout, even
# though `[ -d .git ]` is true.
printf '%s\n' "$cd_victim/.git" >"$cd_repo/.git/commondir"
printf 'ref: refs/heads/main\n' >"$cd_repo/.git/HEAD"
cd_victim_listing_before="$(find "$cd_victim/.git" | sort)"
cd_resolved="$(run_reconcile_at "$cd_repo" "$cd_xdg" "$cd_log" 2>"$tmp_root/cd.err")" ||
    fail "reconciliation aborted post-create for a .git directory with its own commondir file instead of skipping it"
[ "$cd_resolved" = "$cd_repo" ] ||
    fail "a .git-directory-with-commondir checkout was not resolved as its own workspace root (resolved '$cd_resolved', expected '$cd_repo')"
grep -Fq "non-worktree indirection" "$tmp_root/cd.err" ||
    fail "reconciliation did not explain why privileged reconciliation was skipped for a .git directory with its own commondir file"
[ ! -e "$cd_log" ] || [ ! -s "$cd_log" ] ||
    fail "reconciliation invoked sudo against a .git directory with its own commondir file — it must only skip, never trust it directly"
cd_victim_listing_after="$(find "$cd_victim/.git" | sort)"
[ "$cd_victim_listing_before" = "$cd_victim_listing_after" ] ||
    fail "the commondir-redirected victim repository's contents changed despite being skipped, not mutated"
# core.sharedRepository is part of the skipped privileged mutation too — no
# config file should have been created on either side of the redirection.
[ ! -e "$cd_repo/.git/config" ] ||
    fail "reconciliation wrote a Git config (core.sharedRepository or otherwise) directly to the .git directory this shape must skip entirely"
[ ! -e "$cd_victim/.git/config" ] || ! grep -Fq "sharedRepository" "$cd_victim/.git/config" ||
    fail "reconciliation wrote core.sharedRepository to the commondir-redirected victim despite skipping privileged mutation for this shape"

echo "==> symlinked Git markers fail closed before chmod"
symlink_repo="$fixture/workspaces/symlinked"
symlink_target="$fixture/external-git-target"
symlink_config="$fixture/symlink-xdg/git/config"
symlink_log="$fixture/symlink-sudo.log"
mkdir -p "$symlink_repo/subdirectory" "$symlink_target/.git/hooks" "$fixture/symlink-xdg/git"
ln -s "$symlink_target/.git" "$symlink_repo/.git"
chmod 0700 "$symlink_target/.git"
symlink_mode_before="$(ls -ld "$symlink_target/.git" | awk '{ print $1 }')"
if run_reconcile_at "$symlink_repo" "$symlink_config" "$symlink_log" >/dev/null 2>"$tmp_root/symlink.err"; then
    fail "a symlinked Git marker unexpectedly passed permissions reconciliation"
fi
[ ! -e "$symlink_log" ] || [ ! -s "$symlink_log" ] ||
    fail "symlink rejection invoked sudo"
symlink_mode_after="$(ls -ld "$symlink_target/.git" | awk '{ print $1 }')"
[ "$symlink_mode_after" = "$symlink_mode_before" ] ||
    fail "symlink rejection changed the external Git metadata mode"
symlink_safe_entries="$(git config --file "$symlink_config" --get-all safe.directory 2>/dev/null || true)"
! grep -Fqx "$symlink_repo" <<<"$symlink_safe_entries" ||
    fail "symlink rejection persisted safe.directory"

echo "==> permission failures stop before adding safe.directory"
failed_repo="$fixture/workspaces/failed"
failed_config="$fixture/failed-xdg/git/config"
failed_log="$fixture/failed-sudo.log"
mkdir -p "$failed_repo/subdirectory" "$fixture/failed-xdg/git"
git -C "$failed_repo" init -q
mkdir -p "$failed_repo/.git/hooks"
chmod 0700 "$failed_repo/.git"
failed_owner_before="$(ls -dn "$failed_repo/.git" | awk '{ print $3 ":" $4 }')"
if SUDO_FAIL=find run_reconcile_at "$failed_repo" "$failed_config" "$failed_log" >/dev/null 2>"$tmp_root/failed.err"; then
    fail "a failed permissions reconciliation unexpectedly succeeded"
fi
failed_safe_entries="$(git config --file "$failed_config" --get-all safe.directory 2>/dev/null || true)"
! grep -Fqx "$failed_repo" <<<"$failed_safe_entries" ||
    fail "a failed reconciliation persisted safe.directory"
failed_owner_after="$(ls -dn "$failed_repo/.git" | awk '{ print $3 ":" $4 }')"
[ "$failed_owner_after" = "$failed_owner_before" ] ||
    fail "a failed reconciliation changed Git metadata ownership"
grep -Fq "safe to retry" "$tmp_root/failed.err" ||
    fail "a failed reconciliation did not name the retry remedy"

echo "==> an interrupted reconciliation converges to the same state on retry, never leaving a state only rollback could fix (#1241 challenge round 4, finding F12)"
converge_repo="$fixture/workspaces/converge"
converge_config="$fixture/converge-xdg/git/config"
converge_log="$fixture/converge-sudo.log"
converge_fail_bin="$fixture/converge-fail-bin"
mkdir -p "$converge_repo/subdirectory" "$fixture/converge-xdg/git" "$converge_fail_bin"
git -C "$converge_repo" init -q
chmod 0700 "$converge_repo/.git"
cat >"${converge_fail_bin}/chmod" <<'EOF'
#!/bin/sh
echo "simulated interrupted chmod" >&2
exit 1
EOF
chmod 0755 "${converge_fail_bin}/chmod"

# First attempt: sudo chown succeeds, then chmod is interrupted (simulated).
if (
    cd "$converge_repo/subdirectory"
    HOME="$home" XDG_CONFIG_HOME="$fixture/converge-xdg" SUDO_LOG="$converge_log" SUDO_FAIL="" \
        PATH="${converge_fail_bin}:${fake_bin}:${PATH}" \
        bash -c 'set -e; . "$1"; reconcile_workspace_permissions "$2"' _ "$helpers" "$converge_config"
) >/dev/null 2>"$tmp_root/converge.err"; then
    fail "an interrupted reconciliation (chmod failing after chown) unexpectedly succeeded"
fi
grep -Fq "safe to retry" "$tmp_root/converge.err" ||
    fail "an interrupted reconciliation did not name the retry remedy"
[ "$(stat -c '%u' "$converge_repo/.git" 2>/dev/null || stat -f '%u' "$converge_repo/.git")" = "$(id -u)" ] ||
    fail "fixture setup: chown did not complete before the simulated chmod interruption, so this fixture would not test the intended partial state"

# Retry with the real chmod restored (no PATH override): must converge to
# the fully-reconciled state, proving the interruption above left nothing
# only a rollback could have fixed.
converge_resolved="$(run_reconcile_at "$converge_repo" "$converge_config" "$converge_log")"
[ "$converge_resolved" = "$converge_repo" ] ||
    fail "the retried reconciliation resolved workspace root was '$converge_resolved', expected '$converge_repo'"
[ "$(git_mode "$converge_repo/.git")" = "2775" ] ||
    fail "the retried reconciliation did not converge to the setgid, group-writable directory mode"
[ "$(git -C "$converge_repo" config core.sharedRepository)" = "0664" ] ||
    fail "the retried reconciliation did not converge to configuring core.sharedRepository"

echo "==> only repository-managed hook names are chmodded"
hook_fixture="$fixture/managed-hooks"
mkdir -p "$hook_fixture/.devcontainer/hooks"
# A real repository, not just a directory shaped like one: install_repo_managed_hooks
# resolves its target via `git rev-parse --git-common-dir` (#1241 review
# round 1, finding F20), which requires genuine Git metadata to answer.
git -C "$hook_fixture" init -q
printf '%s\n' '#!/bin/sh' 'echo managed' >"$hook_fixture/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_fixture/.devcontainer/hooks/post-checkout"
printf '%s\n' sample >"$hook_fixture/.git/hooks/applypatch-msg.sample"
chmod 0644 "$hook_fixture/.git/hooks/applypatch-msg.sample"
(
    cd "$hook_fixture"
    . "$managed_helpers"
    install_repo_managed_hooks
)
[ -x "$hook_fixture/.git/hooks/post-checkout" ] ||
    fail "the managed hook was not made executable"
[ ! -x "$hook_fixture/.git/hooks/applypatch-msg.sample" ] ||
    fail "the Git sample hook was unexpectedly chmodded"
grep -Fqx 'echo managed' "$hook_fixture/.git/hooks/post-checkout" ||
    fail "the managed hook was not copied"

echo "==> managed hooks install correctly from a linked worktree, where .git is a file (#1241 review round 1, finding F20)"
hook_wt_main="$fixture/workspaces/hook-wt-main"
hook_wt_linked="$fixture/workspaces/hook-wt-linked"
mkdir -p "$hook_wt_main"
git -C "$hook_wt_main" init -q
git -C "$hook_wt_main" -c user.name=fixture -c user.email=fixture@example.test commit --allow-empty -qm init
hook_wt_main="$(cd "$hook_wt_main" && pwd -P)"
git -C "$hook_wt_main" worktree add -q "$hook_wt_linked" -b hook-wt-branch
hook_wt_linked="$(cd "$hook_wt_linked" && pwd -P)"
mkdir -p "$hook_wt_linked/.devcontainer/hooks"
[ -f "$hook_wt_linked/.git" ] ||
    fail "fixture setup: expected the linked worktree's .git to be a file"
printf '%s\n' '#!/bin/sh' 'echo managed-worktree' >"$hook_wt_linked/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_wt_linked/.devcontainer/hooks/post-checkout"
(
    cd "$hook_wt_linked"
    . "$managed_helpers"
    install_repo_managed_hooks
) || fail "install_repo_managed_hooks aborted from a linked worktree instead of resolving the shared hooks directory"
[ -x "$hook_wt_main/.git/hooks/post-checkout" ] ||
    fail "the managed hook was not installed into the linked worktree's shared (main-checkout) hooks directory"
grep -Fqx 'echo managed-worktree' "$hook_wt_main/.git/hooks/post-checkout" ||
    fail "the managed hook content was not copied for a linked worktree"

echo "==> a managed hook that cannot be made executable fails post-create loudly (#1241 item 5)"
hook_fail_fixture="$fixture/managed-hooks-fail"
hook_fail_bin="$fixture/hook-fail-bin"
mkdir -p "$hook_fail_fixture/.devcontainer/hooks" "$hook_fail_bin"
git -C "$hook_fail_fixture" init -q
printf '%s\n' '#!/bin/sh' 'echo managed' >"$hook_fail_fixture/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_fail_fixture/.devcontainer/hooks/post-checkout"
cat >"$hook_fail_bin/chmod" <<'CHMODFAIL'
#!/bin/sh
echo "simulated chmod +x failure" >&2
exit 1
CHMODFAIL
chmod 0755 "$hook_fail_bin/chmod"
if (
    cd "$hook_fail_fixture"
    PATH="$hook_fail_bin:$PATH"
    . "$managed_helpers"
    install_repo_managed_hooks
) >/dev/null 2>"$tmp_root/hook-fail.err"; then
    fail "a chmod +x failure on a managed hook did not abort install_repo_managed_hooks"
fi
grep -q . "$tmp_root/hook-fail.err" ||
    fail "a chmod +x failure on a managed hook produced no diagnostic output"

echo "==> hooks installation skips (never writes), rather than aborting, for a genuine --separate-git-dir checkout (#1241 integration round 2, Codex finding 4056048551)"
hook_sgd_repo="$fixture/workspaces/hook-sgd-repo"
hook_sgd_gitdir="$fixture/hook-sgd-external-gitdir"
mkdir -p "$hook_sgd_repo"
git init -q --separate-git-dir="$hook_sgd_gitdir" "$hook_sgd_repo"
hook_sgd_repo="$(cd "$hook_sgd_repo" && pwd -P)"
mkdir -p "$hook_sgd_repo/.devcontainer/hooks"
printf '%s\n' '#!/bin/sh' 'echo managed-sgd' >"$hook_sgd_repo/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_sgd_repo/.devcontainer/hooks/post-checkout"
hook_sgd_gitdir_listing_before="$(find "$hook_sgd_gitdir" | sort)"
(
    cd "$hook_sgd_repo"
    . "$managed_helpers"
    install_repo_managed_hooks
) >/dev/null 2>"$tmp_root/hook-sgd.err" ||
    fail "hooks installation aborted for a genuine --separate-git-dir checkout instead of skipping it"
grep -Fq "non-worktree indirection" "$tmp_root/hook-sgd.err" ||
    fail "hooks installation did not explain why it skipped a --separate-git-dir checkout"
hook_sgd_gitdir_listing_after="$(find "$hook_sgd_gitdir" | sort)"
[ "$hook_sgd_gitdir_listing_before" = "$hook_sgd_gitdir_listing_after" ] ||
    fail "hooks installation wrote into a --separate-git-dir checkout's external Git directory despite skipping it"
[ ! -e "$hook_sgd_gitdir/hooks/post-checkout" ] ||
    fail "hooks installation copied a managed hook into a skipped --separate-git-dir checkout"

echo "==> hooks installation skips (never writes), rather than installing into the wrong tree, for a .git DIRECTORY containing its own commondir file (#1241 integration round 5, Codex finding 4056410777)"
hook_cd_repo="$fixture/workspaces/hook-cd-repo"
hook_cd_victim="$fixture/hook-cd-victim-common"
mkdir -p "$hook_cd_repo/.git" "$hook_cd_repo/.devcontainer/hooks" "$hook_cd_victim"
git -C "$hook_cd_victim" init -q
hook_cd_victim="$(cd "$hook_cd_victim" && pwd -P)"
printf '%s\n' "$hook_cd_victim/.git" >"$hook_cd_repo/.git/commondir"
printf 'ref: refs/heads/main\n' >"$hook_cd_repo/.git/HEAD"
printf '%s\n' '#!/bin/sh' 'echo managed-cd' >"$hook_cd_repo/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_cd_repo/.devcontainer/hooks/post-checkout"
hook_cd_victim_hooks_before="$(find "$hook_cd_victim/.git/hooks" | sort)"
(
    cd "$hook_cd_repo"
    . "$managed_helpers"
    install_repo_managed_hooks
) >/dev/null 2>"$tmp_root/hook-cd.err" ||
    fail "hooks installation aborted for a .git directory with its own commondir file instead of skipping it"
grep -Fq "non-worktree indirection" "$tmp_root/hook-cd.err" ||
    fail "hooks installation did not explain why it skipped a .git directory with its own commondir file"
hook_cd_victim_hooks_after="$(find "$hook_cd_victim/.git/hooks" | sort)"
[ "$hook_cd_victim_hooks_before" = "$hook_cd_victim_hooks_after" ] ||
    fail "hooks installation wrote into the commondir-redirected victim repository's hooks despite skipping it"
[ ! -e "$hook_cd_repo/.git/hooks" ] ||
    fail "hooks installation created a hooks directory directly on the .git directory this shape must skip entirely"

echo "==> hooks installation refuses a crafted admin dir it cannot verify, never writing into the victim it redirects to (#1241 integration round 2, Codex finding 4056048551)"
hook_atk_victim="$fixture/workspaces/hook-atk-victim"
hook_atk_attacker="$fixture/workspaces/hook-atk-attacker"
hook_atk_fake_admin="$fixture/hook-atk-fake-admin"
mkdir -p "$hook_atk_victim" "$hook_atk_attacker" "$hook_atk_fake_admin"
git -C "$hook_atk_victim" init -q
hook_atk_victim="$(cd "$hook_atk_victim" && pwd -P)"
hook_atk_victim_hooks_before="$(find "$hook_atk_victim/.git/hooks" | sort)"
mkdir -p "$hook_atk_attacker/.devcontainer/hooks"
printf '%s\n' '#!/bin/sh' 'echo managed-attack' >"$hook_atk_attacker/.devcontainer/hooks/post-checkout"
chmod 0644 "$hook_atk_attacker/.devcontainer/hooks/post-checkout"
# Same crafted-admin-dir shape as resolve_git_dir's own F19 fixture: the
# fake admin dir's OWN reverse pointer correctly names the attacker's .git
# file, but its "commondir" redirects to the unrelated victim repository.
hook_atk_attacker="$(cd "$hook_atk_attacker" && pwd -P)"
printf 'gitdir: %s/.git\n' "$hook_atk_attacker" >"$hook_atk_fake_admin/gitdir"
printf '%s\n' "$hook_atk_victim/.git" >"$hook_atk_fake_admin/commondir"
printf 'ref: refs/heads/main\n' >"$hook_atk_fake_admin/HEAD"
printf 'gitdir: %s\n' "$hook_atk_fake_admin" >"$hook_atk_attacker/.git"
if (
    cd "$hook_atk_attacker"
    . "$managed_helpers"
    install_repo_managed_hooks
) >/dev/null 2>"$tmp_root/hook-atk.err"; then
    fail "hooks installation accepted a crafted admin dir whose commondir redirects to an unrelated repository"
fi
hook_atk_victim_hooks_after="$(find "$hook_atk_victim/.git/hooks" | sort)"
[ "$hook_atk_victim_hooks_before" = "$hook_atk_victim_hooks_after" ] ||
    fail "hooks installation copied a managed hook into the unrelated victim repository's hooks directory"
[ ! -e "$hook_atk_victim/.git/hooks/post-checkout" ] ||
    fail "the crafted redirect's managed hook landed in the victim repository"

echo "devcontainer Git permissions: all cases passed"
