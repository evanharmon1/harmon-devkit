#!/usr/bin/env bash
set -euo pipefail

mode="${1:-apply}"
defaults_src="${2:-/usr/local/share/devcontainer-config/antigravity-settings.json}"
workspace="${3:-$PWD}"
settings_dir="$HOME/.gemini/antigravity-cli"
settings_path="$settings_dir/settings.json"
backup_path="$settings_dir/settings.json.harmon-init-autonomy-backup"
managed_keys='["toolPermission","artifactReviewPolicy","allowNonWorkspaceAccess","enableTerminalSandbox"]'

valid_object() {
    jq -s -e 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null
}

atomic_replace() {
    local source_path="$1"
    local destination_path="$2"
    chmod 0600 "$source_path"
    mv -f "$source_path" "$destination_path"
}

mkdir -p "$settings_dir"

case "$mode" in
apply)
    if [ ! -f "$defaults_src" ]; then
        echo "Antigravity defaults not found at ${defaults_src}." >&2
        exit 1
    fi
    if ! valid_object "$defaults_src"; then
        echo "Cannot merge invalid Antigravity defaults from ${defaults_src}." >&2
        exit 1
    fi

    if [ ! -f "$settings_path" ]; then
        printf '{}\n' >"$settings_path"
        chmod 0600 "$settings_path"
    elif ! valid_object "$settings_path"; then
        echo "Cannot merge invalid Antigravity settings; leaving ${settings_path} unchanged." >&2
        exit 0
    fi

    # Capture only the keys this policy owns. A later restore can put those
    # values (including absence) back without discarding unrelated user changes.
    if [ ! -f "$backup_path" ]; then
        backup_tmp="$(mktemp "${settings_dir}/settings.backup.tmp.XXXXXX")"
        trap 'rm -f "${backup_tmp:-}" "${settings_tmp:-}"' EXIT
        jq --argjson keys "$managed_keys" --arg workspace "$workspace" '
            . as $settings |
            reduce $keys[] as $key (
                {
                    schemaVersion: 3,
                    present: [],
                    values: {},
                    introducedWorkspaces: (
                        if ((($settings.trustedWorkspaces | type) == "array") and
                            (($settings.trustedWorkspaces | index($workspace)) != null))
                        then [] else [$workspace] end
                    ),
                    trustedWorkspacesKeyWasPresent: ($settings | has("trustedWorkspaces"))
                };
                if ($settings | has($key)) then
                    .present += [$key] | .values[$key] = $settings[$key]
                else
                    .
                end
            )
        ' "$settings_path" >"$backup_tmp"
        atomic_replace "$backup_tmp" "$backup_path"
    elif ! jq -e --argjson keys "$managed_keys" '
        type == "object" and .schemaVersion == 3 and
        (.present | type == "array") and (.values | type == "object") and
        (.introducedWorkspaces | type == "array") and
        ([.introducedWorkspaces[] | select(type != "string")] | length == 0) and
        (.trustedWorkspacesKeyWasPresent | type == "boolean") and
        ([.present[] as $key | select(($keys | index($key)) == null)] | length == 0)
    ' "$backup_path" >/dev/null; then
        echo "Cannot update Antigravity policy with invalid rollback state at ${backup_path}." >&2
        exit 1
    fi

    # A named volume can outlive a repository move or rename. Track every new
    # workspace this policy adds so opt-out can remove the complete introduced
    # set while retaining paths the user had already trusted themselves.
    if ! jq -e --arg workspace "$workspace" '
        ((.trustedWorkspaces | type) == "array") and
        ((.trustedWorkspaces | index($workspace)) != null)
    ' "$settings_path" >/dev/null &&
        ! jq -e --arg workspace "$workspace" \
            '.introducedWorkspaces | index($workspace) != null' "$backup_path" >/dev/null; then
        backup_tmp="$(mktemp "${settings_dir}/settings.backup.tmp.XXXXXX")"
        trap 'rm -f "${backup_tmp:-}" "${settings_tmp:-}"' EXIT
        jq --arg workspace "$workspace" \
            '.introducedWorkspaces += [$workspace] | .introducedWorkspaces |= unique' \
            "$backup_path" >"$backup_tmp"
        atomic_replace "$backup_tmp" "$backup_path"
    fi

    settings_tmp="$(mktemp "${settings_dir}/settings.json.tmp.XXXXXX")"
    trap 'rm -f "${backup_tmp:-}" "${settings_tmp:-}"' EXIT
    if ! jq -s --arg workspace "$workspace" '
        .[0] as $current | .[1] as $policy |
        ($current * $policy) |
        .trustedWorkspaces = (
            (if ($current.trustedWorkspaces | type) == "array"
             then $current.trustedWorkspaces else [] end) + [$workspace] |
            map(select(type == "string")) | unique
        )
    ' "$settings_path" "$defaults_src" >"$settings_tmp"; then
        echo "Failed to merge Antigravity settings; leaving ${settings_path} unchanged." >&2
        exit 1
    fi

    if ! cmp -s "$settings_tmp" "$settings_path"; then
        echo "==> Applying dev container Antigravity CLI autonomy policy..."
        atomic_replace "$settings_tmp" "$settings_path"
    fi
    ;;
restore)
    [ -f "$backup_path" ] || exit 0
    if [ ! -f "$settings_path" ] || ! valid_object "$settings_path"; then
        echo "Cannot restore Antigravity policy into missing or invalid ${settings_path}." >&2
        exit 0
    fi
    if ! jq -e --argjson keys "$managed_keys" '
        type == "object" and .schemaVersion == 3 and
        (.present | type == "array") and (.values | type == "object") and
        (.introducedWorkspaces | type == "array") and
        ([.introducedWorkspaces[] | select(type != "string")] | length == 0) and
        (.trustedWorkspacesKeyWasPresent | type == "boolean") and
        ([.present[] as $key | select(($keys | index($key)) == null)] | length == 0)
    ' "$backup_path" >/dev/null; then
        echo "Cannot restore invalid Antigravity rollback state at ${backup_path}." >&2
        exit 1
    fi

    settings_tmp="$(mktemp "${settings_dir}/settings.json.tmp.XXXXXX")"
    trap 'rm -f "${settings_tmp:-}"' EXIT
    jq -s --argjson keys "$managed_keys" '
        .[0] as $current | .[1] as $backup |
        reduce $keys[] as $key ($current; del(.[$key])) |
        reduce $backup.present[] as $key (.; .[$key] = $backup.values[$key]) |
        if ((.trustedWorkspaces | type) == "array") then
            .trustedWorkspaces = [
                .trustedWorkspaces[] as $workspace |
                select(($backup.introducedWorkspaces | index($workspace)) == null) |
                $workspace
            ] |
            if ((.trustedWorkspaces | length) == 0 and
                ($backup.trustedWorkspacesKeyWasPresent | not)) then
                del(.trustedWorkspaces)
            else . end
        else . end
    ' "$settings_path" "$backup_path" >"$settings_tmp"
    echo "==> Restoring pre-template Antigravity CLI policy..."
    atomic_replace "$settings_tmp" "$settings_path"
    rm -f "$backup_path"
    ;;
*)
    echo "Usage: $0 <apply|restore> [defaults-file] [workspace]" >&2
    exit 2
    ;;
esac
