#!/usr/bin/env bash
# Shared local freshness check for the vendored integrate and
# dev-flow-support asset directories.
#
# check_vendored_asset_freshness PR REPO SCRIPT_DIR TIMEOUT_BIN returns:
#   0  current, or checkout HEAD is not an ancestor of the PR base
#   2  indeterminate; details are stored in asset_freshness_detail
#   19 definite stale ancestor checkout; details are stored likewise

asset_freshness_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
asset_freshness_universal_dir="$(cd "$asset_freshness_helper_dir/../.." && pwd -P)"
asset_freshness_detail=

check_vendored_asset_freshness() {
    local target_pr=$1 target_repo=$2 script_dir=$3 timeout_bin=$4
    local checkout_root checkout_head base_sha support_dir integrate_path support_path
    local probe probe_status missing_asset_commit

    asset_freshness_detail=
    checkout_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
        asset_freshness_detail="asset freshness indeterminate: cannot locate the checkout containing $script_dir"
        return 2
    }
    checkout_root=$(cd "$checkout_root" && pwd -P) || {
        asset_freshness_detail="asset freshness indeterminate: cannot resolve checkout root $checkout_root"
        return 2
    }
    checkout_head=$(git -C "$checkout_root" rev-parse --verify HEAD 2>/dev/null) || {
        asset_freshness_detail="asset freshness indeterminate: cannot resolve checkout HEAD in $checkout_root"
        return 2
    }
    base_sha=$(run_gh pr view "$target_pr" --repo "$target_repo" \
        --json baseRefOid --jq .baseRefOid 2>/dev/null) || {
        asset_freshness_detail="asset freshness indeterminate: cannot read PR base SHA for $target_repo#$target_pr (checkout HEAD $checkout_head)"
        return 2
    }
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

    # Keep ancestry and the one path-limited history query in a single bounded
    # process. A checkout ahead of or diverged from the PR base is not stale:
    # only an ancestor checkout can be missing a later base asset change.
    probe='git -C "$1" merge-base --is-ancestor "$2" "$3" >/dev/null 2>&1
ancestry_status=$?
case "$ancestry_status" in
    0) ;;
    1) exit 0 ;;
    *) exit "$ancestry_status" ;;
esac
git -C "$1" log --max-count=1 --format=%H "$2..$3" -- "$4" "$5"
'
    probe_status=0
    if [ -n "$timeout_bin" ]; then
        missing_asset_commit=$("$timeout_bin" -k 1 10 bash -c "$probe" \
            asset-freshness "$checkout_root" "$checkout_head" "$base_sha" \
            "$integrate_path" "$support_path" 2>&1) || probe_status=$?
    else
        missing_asset_commit=$(bash -c "$probe" asset-freshness \
            "$checkout_root" "$checkout_head" "$base_sha" \
            "$integrate_path" "$support_path" 2>&1) || probe_status=$?
    fi
    if [ "$probe_status" -ne 0 ]; then
        if [ "$probe_status" -eq 124 ] || [ "$probe_status" -eq 137 ]; then
            asset_freshness_detail="asset freshness indeterminate: bounded local history read timed out for PR base $base_sha (checkout HEAD $checkout_head); no fetch was attempted"
        else
            asset_freshness_detail="asset freshness indeterminate: cannot inspect local PR base $base_sha for $target_repo#$target_pr (checkout HEAD $checkout_head); fetch the PR's base commit from its base repository, then rerun; no automatic fetch was attempted: $missing_asset_commit"
        fi
        return 2
    fi
    [ -z "$missing_asset_commit" ] || {
        asset_freshness_detail="asset freshness refused: checkout HEAD $checkout_head is an ancestor of PR base $base_sha, which contains vendored integrate or dev-flow-support asset change $missing_asset_commit; run from the lane worktree or update this checkout"
        return 19
    }
    return 0
}
