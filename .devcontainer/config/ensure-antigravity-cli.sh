#!/usr/bin/env bash
set -euo pipefail

# Compatibility bridge: generated repos may consume a previously published
# shared image while the image change in this release is still propagating.
version="1.1.11"
build="4956531888881664"

install_dir="$HOME/.local/bin"
real_bin="${install_dir}/agy-real"
link_bin="${install_dir}/agy"
real_ownership_file="${install_dir}/.agy-real.harmon-init-owned"
real_transaction_file="${install_dir}/.agy-real.harmon-init-transaction"
launcher_ownership_file="${install_dir}/.agy.harmon-init-owned"
launcher_transaction_file="${install_dir}/.agy.harmon-init-transaction"
lock_file="${install_dir}/.agy.harmon-init-lock"
lock_backend=""
work_dir=""

release_lock() {
    if [ "$lock_backend" = "shlock" ] && [ -f "$lock_file" ] && [ ! -L "$lock_file" ] &&
        [ "$(cat "$lock_file")" = "$$" ]; then
        rm -f "$lock_file"
    fi
    lock_backend=""
}

cleanup() {
    if [ -n "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
    release_lock
}

trap cleanup EXIT

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        # Lock the already-open install directory instead of a pathname that
        # could be replaced while this process holds the lock. The descriptor
        # remains open until the script exits.
        exec 9<"$install_dir"
        if ! flock -n 9; then
            echo "Antigravity launcher reconciliation is already running" >&2
            return 1
        fi
        lock_backend="flock"
    elif command -v shlock >/dev/null 2>&1; then
        # macOS test/development hosts do not ship flock. shlock uses an
        # atomic link and safely reaps a dead PID's stale lock.
        if ! shlock -f "$lock_file" -p "$$"; then
            echo "Antigravity launcher reconciliation is already running" >&2
            return 1
        fi
        lock_backend="shlock"
    else
        echo "Antigravity launcher reconciliation requires flock or shlock" >&2
        return 1
    fi
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

metadata_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

path_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

file_sha512() {
    if command -v sha512sum >/dev/null 2>&1; then
        sha512sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 512 "$1" | awk '{print $1}'
    else
        echo "SHA-512 verification requires sha512sum or shasum" >&2
        return 1
    fi
}

proof_value() {
    sed -n "s/^$2=//p" "$1" | head -1
}

proof_matches() (
    proof="$1"
    path="$2"
    expected_identity=""
    actual_identity=""
    expected_digest=""
    actual_digest=""
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
    expected_identity="$(proof_value "$proof" identity)"
    [ -n "$expected_identity" ] || return 1
    actual_identity="$(path_identity "$path" 2>/dev/null)" || return 1
    [ -n "$actual_identity" ] && [ "$expected_identity" = "$actual_identity" ] || return 1

    case "$(proof_value "$proof" type)" in
    file)
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        expected_digest="$(proof_value "$proof" sha512)"
        [ -n "$expected_digest" ] || return 1
        actual_digest="$(file_sha512 "$path")" || return 1
        [ -n "$actual_digest" ] && [ "$expected_digest" = "$actual_digest" ]
        ;;
    symlink)
        [ -L "$path" ] &&
            [ "$(proof_value "$proof" target)" = "$(readlink "$path")" ]
        ;;
    *) return 1 ;;
    esac
)

write_proof() (
    path="$1"
    proof="$2"
    temp_name="$3"
    proof_tmp="$(mktemp "${proof}.tmp.XXXXXX")"
    trap 'rm -f "$proof_tmp"' EXIT

    identity="$(path_identity "$path")" || return 1
    [ -n "$identity" ] || return 1
    if [ -L "$path" ]; then
        target="$(readlink "$path")" || return 1
        [ -n "$target" ] || return 1
        printf 'type=symlink\nidentity=%s\ntarget=%s\ntemp_name=%s\n' \
            "$identity" "$target" "$temp_name" >"$proof_tmp"
    else
        digest="$(file_sha512 "$path")" || return 1
        [ -n "$digest" ] || return 1
        printf 'type=file\nidentity=%s\nsha512=%s\ntemp_name=%s\n' \
            "$identity" "$digest" "$temp_name" >"$proof_tmp"
    fi
    chmod 0600 "$proof_tmp"
    mv -f "$proof_tmp" "$proof"
)

discard_transaction() {
    transaction="$1"
    prefix="$2"
    # Declared (not assigned) here, separately from their eventual
    # command-substitution assignments below: `local x="$(cmd)"` masks
    # cmd's own exit status behind local's own — the declaration alone
    # does not (#1241 integration round 5, Gemini findings
    # 4056368199/4056368200/4056368201/4056368204).
    local temp_path quarantine_dir quarantine_path
    temp_name="$(proof_value "$transaction" temp_name 2>/dev/null || true)"
    case "$temp_name" in
    "${prefix}.tmp."*)
        temp_path="${install_dir}/${temp_name}"
        # Quarantine into a FRESH, PRIVATE per-call directory (mktemp -d,
        # beside temp_path so the rename stays on the same filesystem and
        # atomic) before validating, then delete — not a same-directory
        # sibling name created with a plain mktemp, then rm'd, then mv'd
        # onto: that create-then-remove-then-move sequence makes the
        # quarantine name publicly observable in the window between the
        # create and the remove, and the final move was a plain mv -f, not
        # no-clobber — together still leaving a window a racing process
        # could exploit (#1241 item 7; review round 3, finding F6; hardened
        # in integration round 2 after Codex/Gemini re-raised the same gap
        # against this exact remedy). The move into the private directory
        # is no-clobber (-n) with no prior rm: nothing can have pre-created
        # a path inside a directory nobody else knows exists, and a refused
        # move is treated as a failed quarantine — the delete below never
        # runs.
        if path_exists "$temp_path"; then
            quarantine_dir="$(mktemp -d "${install_dir}/.harmon-init-discard.XXXXXX" 2>/dev/null)" || quarantine_dir=""
            if [ -n "$quarantine_dir" ]; then
                quarantine_path="${quarantine_dir}/proof"
                if mv -n "$temp_path" "$quarantine_path" 2>/dev/null && [ -e "$quarantine_path" ]; then
                    if proof_matches "$transaction" "$quarantine_path"; then
                        rm -f "$quarantine_path"
                    else
                        echo "Transaction proof for ${quarantine_path} (quarantined from ${temp_path}) no longer matches its content; leaving it for manual review" >&2
                    fi
                fi
                rmdir "$quarantine_dir" 2>/dev/null || true
            fi
        fi
        ;;
    esac
    rm -f "$transaction"
}

recover_transaction() {
    transaction="$1"
    ownership="$2"
    path="$3"
    prefix="$4"
    metadata_exists "$transaction" || return 0
    if proof_matches "$transaction" "$path"; then
        mv -f "$transaction" "$ownership"
    else
        discard_transaction "$transaction" "$prefix"
    fi
}

remove_if_owned() {
    proof="$1"
    path="$2"
    label="$3"
    prior_temp_name="$(proof_value "$proof" temp_name 2>/dev/null || true)"
    case "$prior_temp_name" in
    "$(basename "$path")".harmon-init-quarantine.*)
        prior_quarantine="$(dirname "$path")/${prior_temp_name}"
        # Quarantine into a FRESH, PRIVATE per-call directory (mktemp -d,
        # beside prior_quarantine so the rename stays on the same
        # filesystem and atomic) before validating, instead of a same-
        # directory sibling name: nothing else can have pre-created a path
        # inside a directory nobody else knows exists. Both moves are
        # no-clobber (-n): if the first one's destination somehow already
        # exists, that is a failed quarantine and the delete below is
        # refused; if the SECOND (restore-on-mismatch) move finds a
        # concurrent process has already recreated prior_quarantine,
        # refusing to overwrite it is exactly what avoids reintroducing the
        # concurrent-replacement race this whole mechanism exists to close
        # — the recovered generation stays retained under its private
        # directory instead of being silently dropped or clobbering the
        # concurrent write (#1241 review round 3, finding F6; hardened in
        # review round 5, finding F24 — the original same-directory
        # sibling name and forced restore move left that exact race open).
        if path_exists "$prior_quarantine"; then
            recheck_dir="$(mktemp -d "$(dirname "$prior_quarantine")/.harmon-init-recheck.XXXXXX" 2>/dev/null)" || recheck_dir=""
            if [ -n "$recheck_dir" ]; then
                recheck="${recheck_dir}/$(basename "$prior_quarantine")"
                if mv -n "$prior_quarantine" "$recheck" 2>/dev/null && [ -e "$recheck" ]; then
                    if proof_matches "$proof" "$recheck"; then
                        if ! rm -f "$recheck"; then
                            echo "Could not remove recovered managed ${label} at ${recheck} (quarantined from ${prior_quarantine})" >&2
                            return 1
                        fi
                        rmdir "$recheck_dir" 2>/dev/null || true
                        rm -f "$proof"
                        return 0
                    fi
                    # Not the recorded generation after all — try to restore
                    # it under its original name, but never clobber a
                    # concurrent replacement: mv -n either succeeds (nothing
                    # is there) or leaves both files exactly where they are.
                    if mv -n "$recheck" "$prior_quarantine" 2>/dev/null && [ ! -e "$recheck" ]; then
                        rmdir "$recheck_dir" 2>/dev/null || true
                    else
                        echo "A concurrent replacement occupies ${prior_quarantine}; retaining the recovered generation at ${recheck} for manual review" >&2
                    fi
                else
                    # The quarantine move itself failed or was refused —
                    # a failed quarantine refuses the delete entirely and
                    # falls through untouched.
                    rmdir "$recheck_dir" 2>/dev/null || true
                fi
            fi
        fi
        ;;
    esac
    if ! proof_matches "$proof" "$path"; then
        rm -f "$proof"
        return 0
    fi

    quarantine="$(mktemp "${path}.harmon-init-quarantine.XXXXXX")"
    rm -f "$quarantine"
    if ! write_proof "$path" "$proof" "$(basename "$quarantine")"; then
        echo "Could not record managed ${label} cleanup recovery state" >&2
        return 1
    fi
    if ! mv -f "$path" "$quarantine"; then
        echo "Could not quarantine managed ${label} before cleanup" >&2
        return 1
    fi

    # Renaming captures one exact generation. Revalidate that moved inode and
    # immutable content before deleting it, so a replacement racing the public
    # pathname is never deleted on the strength of an earlier proof check.
    if proof_matches "$proof" "$quarantine"; then
        rm -f "$quarantine"
        rm -f "$proof"
        return 0
    fi

    # The captured generation was not ours. Restore without overwriting a new
    # public value; if another actor already filled the pathname, retain the
    # quarantined bytes and fail loudly with their recovery location.
    if [ -L "$quarantine" ]; then
        quarantine_target="$(readlink "$quarantine")"
        if ln -s -n "$quarantine_target" "$path" 2>/dev/null; then
            rm -f "$quarantine"
        fi
    elif [ -f "$quarantine" ]; then
        if ln -n "$quarantine" "$path" 2>/dev/null; then
            rm -f "$quarantine"
        fi
    fi
    rm -f "$proof"
    if path_exists "$quarantine"; then
        echo "Concurrent replacement preserved at ${quarantine}; refusing ${label} cleanup" >&2
        return 1
    fi
    return 0
}

publish_owned_launcher() (
    link_tmp="$(mktemp "${install_dir}/agy.tmp.XXXXXX")"
    rm -f "$link_tmp"
    trap 'rm -f "$link_tmp"' EXIT
    ln -s "$real_bin" "$link_tmp"
    write_proof "$link_tmp" "$launcher_transaction_file" "$(basename "$link_tmp")"
    rm -f "$link_bin"
    mv -f "$link_tmp" "$link_bin"
    mv -f "$launcher_transaction_file" "$launcher_ownership_file"
)

install_owned_real() (
    source_bin="$1"
    install -d -m 0755 "$install_dir"
    real_tmp="$(mktemp "${install_dir}/agy-real.tmp.XXXXXX")"
    trap 'rm -f "$real_tmp"' EXIT

    install -m 0755 "$source_bin" "$real_tmp"
    # The transaction describes the new inode and immutable installed content.
    # Publishing it first makes either side of the executable replacement
    # recoverable without treating a filename, version, or mutable inode alone
    # as ownership proof.
    write_proof "$real_tmp" "$real_transaction_file" "$(basename "$real_tmp")"
    rm -f "$real_bin"
    mv -f "$real_tmp" "$real_bin"
    mv -f "$real_transaction_file" "$real_ownership_file"
)

install -d -m 0755 "$install_dir"
acquire_lock
recover_transaction "$real_transaction_file" "$real_ownership_file" "$real_bin" "agy-real"
recover_transaction "$launcher_transaction_file" "$launcher_ownership_file" "$link_bin" "agy"

# HARMON_BOT_AUTONOMY_ANTIGRAVITY is the rendered containerEnv marker (bot
# and dev devcontainer.json twins, from the use_antigravity_cli Copier
# answer) — the only channel this verbatim, template-twinned script may read
# to learn that per-repo answer. Anything other than "enabled" (including
# absent, on an image built before this marker existed) means: no download,
# and remove each path only when its own identity-and-content proof matches.
# Launcher shape and executable version are never ownership authority.
# Independent files and symlinks at either path survive a disabled run.
if [ "${HARMON_BOT_AUTONOMY_ANTIGRAVITY:-}" != "enabled" ]; then
    cleanup_ok=true
    remove_if_owned "$launcher_ownership_file" "$link_bin" "agy launcher" || cleanup_ok=false
    remove_if_owned "$real_ownership_file" "$real_bin" "agy-real executable" || cleanup_ok=false
    [ "$cleanup_ok" = true ] || exit 1
    exit 0
fi

# Once the pinned image supplies this exact version, exit without touching the
# network. A stale image version falls through to the user-local compatibility
# copy, which takes precedence in the repo-managed shell PATH.
if [ -x "$real_bin" ] &&
    [ "$("$real_bin" --version | head -1)" = "$version" ]; then
    # Version equality proves compatibility, not ownership. Retain a proof only
    # while both identity and immutable installed content still match.
    if ! proof_matches "$real_ownership_file" "$real_bin"; then
        rm -f "$real_ownership_file"
    fi
    publish_owned_launcher
    exit 0
fi

system_binary="${HARMON_ANTIGRAVITY_SYSTEM_BINARY:-/usr/local/bin/agy}"
if [ -x "$system_binary" ] && [ "$("$system_binary" --version | head -1)" = "$version" ]; then
    # Reconcile only a compatibility copy already left in the persistent
    # volume. Interactive shells put ~/.local/bin first, so an older executable
    # would shadow the newly pinned and smoke-tested shared-image binary. Do not
    # create a new shadow copy when the image binary is already sufficient.
    if ! proof_matches "$real_ownership_file" "$real_bin"; then
        rm -f "$real_ownership_file"
    fi
    if [ -x "$real_bin" ]; then
        install_owned_real "$system_binary"
        publish_owned_launcher
    elif [ -L "$link_bin" ]; then
        # No local real copy to (re)point at, so this branch installs
        # nothing — only remove a leftover $link_bin in the two shapes
        # that must not persist: a dangling symlink (its target already
        # gone, e.g. after a prior agy-real was removed by a toggle-off/on
        # cycle or a stale image) — already a broken launcher on its own —
        # or a symlink to an existing directory, which
        # bot-autonomy/antigravity.sh's install_wrapper cannot safely
        # replace: its unguarded `mv -f "$tmp" "$link_bin"` lands *inside*
        # an existing directory target instead of replacing the link (a
        # later `ln -sfn` is unaffected by that same shape). A regular
        # file, a valid wrapper, or a symlink to an existing file is left
        # exactly as found: either is safe for a later `mv -f` or
        # `ln -sfn` to replace, and removing one here — with nothing on
        # this branch to replace it with — would destroy a still-valid
        # wrapper for good in the dev profile, which has no follow-on
        # apply step to reinstall it (#1171).
        if [ ! -e "$link_bin" ] || [ -d "$link_bin" ]; then
            rm -f "$link_bin" "$launcher_ownership_file"
        fi
    fi
    exit 0
fi

case "$(uname -m)" in
x86_64)
    platform="linux-x64"
    archive="cli_linux_x64"
    sha512="32d64529cf035ab9790352069dd0df4525d7c920b42872de1775e65455e77fd983b37a6dee81a6345b060c98d5f350729bb5e2ae881bbda80f46b7487af4588d"
    ;;
aarch64 | arm64)
    platform="linux-arm"
    archive="cli_linux_arm64"
    sha512="fb1acacdbde606a60a8002b6dc0a8c9800bb84aef3add069f843f6ffa3efaafe4a52fce440505c6f16aebd6b1257cce5ecfaec2dbab21732c625943422318cdb"
    ;;
*)
    echo "Unsupported architecture for Antigravity CLI: $(uname -m)" >&2
    exit 1
    ;;
esac

work_dir="$(mktemp -d)"
tarball="$work_dir/${archive}.tar.gz"
url="https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${build}/${platform}/${archive}.tar.gz"

echo "==> Installing pinned Antigravity CLI ${version} compatibility copy..."
curl -fsSL --retry 3 "$url" -o "$tarball"
[ "$(file_sha512 "$tarball")" = "$sha512" ] || {
    echo "Antigravity CLI archive SHA-512 mismatch" >&2
    exit 1
}
tar -xzf "$tarball" -C "$work_dir" antigravity
install_owned_real "$work_dir/antigravity"
publish_owned_launcher
