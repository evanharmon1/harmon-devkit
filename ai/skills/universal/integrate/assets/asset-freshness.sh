#!/usr/bin/env bash
# Shared local freshness check for the vendored integrate and
# dev-flow-support asset directories.
#
# A checkout is stale only when its HEAD is an ancestor of the PR base AND
# those asset directories differ byte-for-byte between the two trees. A
# shallow checkout or graft file makes ancestry unprovable and is therefore
# indeterminate. Replacement refs are ignored on every Git call.
#
# check_vendored_asset_freshness PR REPO SCRIPT_DIR TIMEOUT_BIN returns:
#   0  checkout is not an ancestor of the base, or the relevant asset bytes match
#   2  indeterminate or permanent base-SHA read failure; details are stored in
#      asset_freshness_detail
#   16 transient remote base-SHA read failure; the caller decides whether to
#      retry
#   19 checkout is an ancestor and the relevant asset bytes differ

asset_freshness_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
asset_freshness_universal_dir="$(cd "$asset_freshness_helper_dir/../.." && pwd -P)"
asset_freshness_detail=

check_vendored_asset_freshness() {
    local target_pr=$1 target_repo=$2 script_dir=$3 timeout_bin=$4
    local checkout_root checkout_head base_sha support_dir integrate_path support_path grafts_path
    local base_sha_status base_sha_error base_sha_status_detail
    local probe probe_status

    asset_freshness_detail=
    checkout_root=$(git --no-replace-objects -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
        asset_freshness_detail="asset freshness indeterminate: cannot locate the checkout containing $script_dir"
        return 2
    }
    checkout_root=$(cd "$checkout_root" && pwd -P) || {
        asset_freshness_detail="asset freshness indeterminate: cannot resolve checkout root $checkout_root"
        return 2
    }
    grafts_path=$(git --no-replace-objects -C "$checkout_root" rev-parse --git-path info/grafts 2>/dev/null) || {
        asset_freshness_detail="asset freshness indeterminate: cannot locate the checkout's graft file"
        return 2
    }
    case "$grafts_path" in
    /*) ;;
    *) grafts_path="$checkout_root/$grafts_path" ;;
    esac
    if [ -e "$grafts_path" ] || [ -L "$grafts_path" ]; then
        asset_freshness_detail="asset freshness indeterminate: checkout has an info/grafts file at $grafts_path, so its commit ancestry cannot be trusted"
        return 2
    fi
    checkout_head=$(git --no-replace-objects -C "$checkout_root" rev-parse --verify HEAD 2>/dev/null) || {
        asset_freshness_detail="asset freshness indeterminate: cannot resolve checkout HEAD in $checkout_root"
        return 2
    }
    if base_sha=$(run_gh pr view "$target_pr" --repo "$target_repo" \
        --json baseRefOid --jq .baseRefOid 2>&1); then
        :
    else
        base_sha_status=$?
        base_sha_error=$base_sha
        if [[ "$base_sha_error" =~ [Hh][Tt][Tt][Pp][[:space:]]+([0-9]{3}) ]]; then
            base_sha_status_detail="HTTP ${BASH_REMATCH[1]}"
        elif [[ "$base_sha_error" == *"Could not resolve to a PullRequest"* ]]; then
            base_sha_status_detail="HTTP 404 (GraphQL)"
        else
            base_sha_status_detail="gh exit $base_sha_status"
        fi
        asset_freshness_detail="asset freshness base-SHA read failed ($base_sha_status_detail): cannot read PR base SHA for $target_repo#$target_pr (checkout HEAD $checkout_head); gh stderr: ${base_sha_error:-<empty>}"

        case "$base_sha_status" in
        124 | 137) return 16 ;;
        4) return 2 ;;
        esac
        if [[ "$base_sha_error" =~ [Hh][Tt][Tt][Pp][[:space:]]+5[0-9][0-9] ]] ||
            grep -Ei \
                '(dial tcp|connection (refused|reset|timed out|closed)|network is unreachable|no such host|temporary failure in name resolution|TLS handshake timeout|i/o timeout|context deadline exceeded|unexpected EOF)' \
                <<<"$base_sha_error" >/dev/null; then
            return 16
        fi
        return 2
    fi
    [[ "$base_sha" =~ ^[0-9a-fA-F]{40}$ ]] || {
        asset_freshness_detail="asset freshness indeterminate: PR base SHA for $target_repo#$target_pr is malformed (checkout HEAD $checkout_head)"
        return 2
    }

    support_dir="$asset_freshness_universal_dir/dev-flow-support/assets"
    [ -d "$support_dir" ] || {
        asset_freshness_detail="asset freshness indeterminate: sibling dev-flow-support assets are missing at $support_dir"
        return 2
    }
    support_dir=$(cd "$support_dir" && pwd -P) || {
        asset_freshness_detail="asset freshness indeterminate: cannot resolve sibling dev-flow-support assets at $support_dir"
        return 2
    }
    case "$asset_freshness_helper_dir" in
    "$checkout_root"/*) integrate_path=${asset_freshness_helper_dir#"$checkout_root"/} ;;
    *)
        asset_freshness_detail="asset freshness indeterminate: integrate assets are outside their Git checkout ($asset_freshness_helper_dir)"
        return 2
        ;;
    esac
    case "$support_dir" in
    "$checkout_root"/*) support_path=${support_dir#"$checkout_root"/} ;;
    *)
        asset_freshness_detail="asset freshness indeterminate: dev-flow-support assets are outside their Git checkout ($support_dir)"
        return 2
        ;;
    esac

    # One bounded probe evaluates the invariant. The output of each Git call
    # is discarded; only its exit status drives the decision, so trace/hint
    # chatter on stderr can never become a stale-asset signal.
    probe='repo=$1
head=$2
base=$3
integrate_path=$4
support_path=$5
grafts_path=$6

if [ -e "$grafts_path" ] || [ -L "$grafts_path" ]; then
    exit 22
fi
shallow=$(git --no-replace-objects -C "$repo" rev-parse --is-shallow-repository 2>/dev/null) || exit 23
case "$shallow" in
    false) ;;
    true) exit 21 ;;
    *) exit 23 ;;
esac

git --no-replace-objects -C "$repo" merge-base --is-ancestor "$head" "$base" >/dev/null 2>&1
ancestry_status=$?
case "$ancestry_status" in
    0) ;;
    1) exit 0 ;;
    *) exit 23 ;;
esac

git --no-replace-objects -C "$repo" diff --quiet "$head" "$base" -- "$integrate_path" "$support_path" >/dev/null 2>&1
diff_status=$?
case "$diff_status" in
    0) exit 0 ;;
    1) exit 19 ;;
    *) exit 23 ;;
esac
'
    probe_status=0
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" -k 1 10 bash -c "$probe" \
            asset-freshness "$checkout_root" "$checkout_head" "$base_sha" \
            "$integrate_path" "$support_path" "$grafts_path" \
            >/dev/null 2>&1 || probe_status=$?
    else
        bash -c "$probe" asset-freshness "$checkout_root" "$checkout_head" \
            "$base_sha" "$integrate_path" "$support_path" "$grafts_path" \
            >/dev/null 2>&1 || probe_status=$?
    fi
    case "$probe_status" in
    0) return 0 ;;
    19)
        asset_freshness_detail="asset freshness refused: checkout HEAD $checkout_head is an ancestor of PR base $base_sha and the vendored integrate or dev-flow-support asset bytes differ; update this checkout to the PR base or newer (fetch and fast-forward), or run from the lane worktree where the recipes allow it"
        return 19
        ;;
    21)
        asset_freshness_detail="asset freshness indeterminate: checkout $checkout_root is shallow, so ancestry to PR base $base_sha cannot be established (checkout HEAD $checkout_head)"
        return 2
        ;;
    22)
        asset_freshness_detail="asset freshness indeterminate: checkout has an info/grafts file at $grafts_path, so its commit ancestry cannot be trusted (checkout HEAD $checkout_head, PR base $base_sha)"
        return 2
        ;;
    124 | 137)
        asset_freshness_detail="asset freshness indeterminate: bounded local asset comparison timed out for PR base $base_sha (checkout HEAD $checkout_head); no fetch was attempted"
        return 2
        ;;
    *)
        asset_freshness_detail="asset freshness indeterminate: cannot inspect local asset bytes and ancestry for PR base $base_sha in $target_repo#$target_pr (checkout HEAD $checkout_head); update this checkout to the PR base or newer (fetch and fast-forward), fetching the PR base from its base repository if it is unavailable locally, then rerun; no automatic fetch was attempted"
        return 2
        ;;
    esac
}
