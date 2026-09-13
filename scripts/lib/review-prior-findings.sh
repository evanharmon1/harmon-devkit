#!/usr/bin/env bash
# Load only receipt-backed, schema-valid pass evidence from a Dev Flow run.
# Writes the run-wide finding-id universe and the earlier same-stage findings
# to caller-owned JSON files. Any malformed receipt or accepted pass fails
# closed; orphaned files under passes/ are deliberately invisible.

review_prior_findings() {
    review_record_dir="$1"
    review_validator="$2"
    review_run_id="$3"
    review_initiated_by="$4"
    review_stage="$5"
    review_round="$6"
    review_head="$7"
    review_known_ids_out="$8"
    review_prior_out="$9"

    review_run_file="$review_record_dir/run.json"
    [ -f "$review_run_file" ] || {
        echo "missing run record $review_run_file" >&2
        return 1
    }
    jq -e '.receipts == null or (.receipts | type == "array")' "$review_run_file" >/dev/null || {
        echo "run record $review_run_file has a non-array receipts field" >&2
        return 1
    }

    printf '[]\n' >"$review_known_ids_out"
    printf '[]\n' >"$review_prior_out"
    review_receipts="$(mktemp "$review_record_dir/.review-receipts.XXXXXX")"
    review_next_ids="$(mktemp "$review_record_dir/.review-known-ids.XXXXXX")"
    review_next_prior="$(mktemp "$review_record_dir/.review-prior.XXXXXX")"
    jq -r '(.receipts // [])[] | select(.kind == "pass") | .file' \
        "$review_run_file" >"$review_receipts" || {
        rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
        return 1
    }

    review_seen=''
    while IFS= read -r review_name; do
        case "$review_name" in
        '' | *[!a-z0-9-]* | -* | *-)
            echo "run receipt has unsafe pass filename: $review_name" >&2
            rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
            return 1
            ;;
        esac
        case " $review_seen " in
        *" $review_name "*)
            echo "run record has duplicate pass receipt: $review_name" >&2
            rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
            return 1
            ;;
        esac
        review_seen="$review_seen $review_name"
        review_pass="$review_record_dir/passes/$review_name.json"
        [ -f "$review_pass" ] || {
            echo "run receipt names missing pass: $review_pass" >&2
            rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
            return 1
        }
        node "$review_validator" envelope "$review_pass" \
            --run-id "$review_run_id" --initiated-by "$review_initiated_by" \
            --known-ids "$review_known_ids_out" --receipt >/dev/null || {
            echo "run receipt names an invalid pass: $review_pass" >&2
            rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
            return 1
        }
        jq -s '.[0] + [.[1].payload.findings[]?.id]' \
            "$review_known_ids_out" "$review_pass" >"$review_next_ids" &&
            mv "$review_next_ids" "$review_known_ids_out" || {
            rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
            return 1
        }
        jq -s --arg stage "$review_stage" --argjson round "$review_round" \
            --arg head "$review_head" '
            .[0] + [.[1] | select(.status == "completed" and .head == $head and
                .payload.stage == $stage and .payload.reviewed_head == $head and
                .payload.round < $round) | .payload.findings[]?] | sort_by(.id)
        ' "$review_prior_out" "$review_pass" >"$review_next_prior" &&
            mv "$review_next_prior" "$review_prior_out" || {
            rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
            return 1
        }
    done <"$review_receipts"
    rm -f "$review_receipts" "$review_next_ids" "$review_next_prior"
}
