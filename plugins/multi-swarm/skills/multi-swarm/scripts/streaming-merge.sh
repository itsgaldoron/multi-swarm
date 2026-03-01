#!/usr/bin/env bash
set -euo pipefail

# Streaming Merge — Merge-as-you-go Pipeline
# Usage: streaming-merge.sh <run-id> <base-branch> <swarm-count> <manifest-path>
# Polls swarm status files and merges each swarm as soon as it completes,
# rather than waiting for all swarms to finish.

RUN_ID="${1:?Usage: streaming-merge.sh <run-id> <base-branch> <swarm-count> <manifest-path>}"
BASE_BRANCH="${2:-main}"
SWARM_COUNT="${3:-4}"
MANIFEST="${4:?Manifest path required}"

STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
LOCK_FILE="$STATE_DIR/base-branch.lock"
RESULTS_FILE="$STATE_DIR/merge-results.json"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

# Track processed swarms (space-separated list of swarm numbers)
MERGED_SET=""
SHUTDOWN=0

# ── Logging ───────────────────────────────────────────────────────────

log() {
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[$timestamp] $*"
}

log_error() {
    log "ERROR: $*"
}

# ── Signal Handling ───────────────────────────────────────────────────

cleanup() {
    log "Received shutdown signal, finishing current operation..."
    SHUTDOWN=1
}

trap cleanup SIGTERM SIGINT

# ── Helpers ───────────────────────────────────────────────────────────

is_merged() {
    local swarm_num="$1"
    echo "$MERGED_SET" | grep -qw "$swarm_num"
}

mark_merged() {
    local swarm_num="$1"
    MERGED_SET="$MERGED_SET $swarm_num"
}

processed_count() {
    if [ -z "$MERGED_SET" ]; then
        echo 0
    else
        echo "$MERGED_SET" | wc -w | tr -d ' '
    fi
}

swarm_phase() {
    local swarm_num="$1"
    local status_file="$STATE_DIR/swarms/swarm-${swarm_num}/status.json"
    if [ -f "$status_file" ]; then
        jq -r '.phase // "unknown"' "$status_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

swarm_summary() {
    local swarm_num="$1"
    local status_file="$STATE_DIR/swarms/swarm-${swarm_num}/status.json"
    if [ -f "$status_file" ]; then
        jq -r '.summary // "Swarm '"$swarm_num"' changes"' "$status_file" 2>/dev/null || echo "Swarm $swarm_num changes"
    else
        echo "Swarm $swarm_num changes"
    fi
}

# Read dependency ordering from manifest
# Returns space-separated list of swarm numbers in merge order
get_merge_order() {
    local order=""
    # Check if manifest defines explicit merge order via dependencies
    local has_deps
    has_deps=$(jq -r '[.swarms[] | select(.dependencies != null)] | length' "$MANIFEST" 2>/dev/null || echo "0")

    if [ "$has_deps" -gt 0 ]; then
        # Topological sort: swarms with no dependencies first
        local resolved=""
        local remaining=""
        for i in $(seq 1 "$SWARM_COUNT"); do
            remaining="$remaining $i"
        done

        while [ -n "$(echo "$remaining" | tr -d ' ')" ]; do
            local progress=0
            for i in $remaining; do
                local deps
                deps=$(jq -r ".swarms[$((i-1))].dependencies // [] | .[]" "$MANIFEST" 2>/dev/null || echo "")
                local all_resolved=1
                for dep in $deps; do
                    if ! echo "$resolved" | grep -qw "$dep"; then
                        all_resolved=0
                        break
                    fi
                done
                if [ "$all_resolved" -eq 1 ]; then
                    resolved="$resolved $i"
                    remaining=$(echo "$remaining" | tr ' ' '\n' | grep -vw "$i" | tr '\n' ' ')
                    progress=1
                fi
            done
            # Break if no progress (circular dependency)
            if [ "$progress" -eq 0 ]; then
                log_error "Circular dependency detected, appending remaining: $remaining"
                resolved="$resolved $remaining"
                break
            fi
        done
        order="$resolved"
    else
        # No dependencies — sequential order
        for i in $(seq 1 "$SWARM_COUNT"); do
            order="$order $i"
        done
    fi

    echo "$order" | tr -s ' ' | sed 's/^ //;s/ $//'
}

# ── Merge Results ─────────────────────────────────────────────────────

init_results() {
    cat > "$RESULTS_FILE" << EOF
{
  "runId": "$RUN_ID",
  "baseBranch": "$BASE_BRANCH",
  "swarmCount": $SWARM_COUNT,
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "completedAt": null,
  "swarms": {}
}
EOF
}

update_result() {
    local swarm_num="$1"
    local status="$2"
    local pr_url="${3:-null}"
    local error_msg="${4:-null}"

    local tmp_file="$RESULTS_FILE.tmp"

    # Quote strings, leave null unquoted
    local pr_val="null"
    if [ "$pr_url" != "null" ]; then
        pr_val="\"$pr_url\""
    fi
    local err_val="null"
    if [ "$error_msg" != "null" ]; then
        err_val="\"$error_msg\""
    fi

    jq --arg num "$swarm_num" \
       --arg status "$status" \
       --argjson pr "$pr_val" \
       --argjson err "$err_val" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.swarms[$num] = {status: $status, prUrl: $pr, error: $err, mergedAt: $ts}' \
       "$RESULTS_FILE" > "$tmp_file" && mv "$tmp_file" "$RESULTS_FILE"
}

finalize_results() {
    local tmp_file="$RESULTS_FILE.tmp"
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.completedAt = $ts' \
       "$RESULTS_FILE" > "$tmp_file" && mv "$tmp_file" "$RESULTS_FILE"
}

# ── Merge Sequence ────────────────────────────────────────────────────

merge_swarm() {
    local swarm_num="$1"
    local slug
    slug=$(jq -r ".swarms[$((swarm_num-1))].slug // \"task-${swarm_num}\"" "$MANIFEST")
    local branch="swarm/${RUN_ID}/${swarm_num}-${slug}"
    local summary
    summary=$(swarm_summary "$swarm_num")

    log "Starting merge for swarm $swarm_num ($slug) on branch $branch"

    # Acquire lock for base branch operations
    exec 9>"$LOCK_FILE"
    if ! flock -w 60 9; then
        log_error "Failed to acquire base branch lock for swarm $swarm_num"
        update_result "$swarm_num" "error" "null" "Failed to acquire lock"
        return 1
    fi

    log "Acquired base branch lock"

    local merge_exit=0
    (
        cd "$PROJECT_ROOT"

        # Step 1: Rebase onto latest base branch
        log "Rebasing $branch onto $BASE_BRANCH..."
        if ! git checkout "$branch" 2>&1; then
            log_error "Failed to checkout $branch"
            update_result "$swarm_num" "error" "null" "Checkout failed"
            exit 1
        fi

        if ! git rebase "$BASE_BRANCH" 2>&1; then
            log_error "Rebase conflict on swarm $swarm_num"
            git rebase --abort 2>/dev/null || true
            git checkout "$BASE_BRANCH" 2>/dev/null || true
            update_result "$swarm_num" "conflict" "null" "Rebase conflict"
            exit 1
        fi

        # Step 2: Push rebased branch
        log "Pushing $branch..."
        if ! git push origin "$branch" --force-with-lease 2>&1; then
            log_error "Push failed for $branch"
            git checkout "$BASE_BRANCH" 2>/dev/null || true
            update_result "$swarm_num" "error" "null" "Push failed"
            exit 1
        fi

        # Step 3: Create PR
        log "Creating PR for swarm $swarm_num..."
        local pr_url
        pr_url=$(gh pr create \
            --base "$BASE_BRANCH" \
            --head "$branch" \
            --title "[Swarm ${swarm_num}] ${summary}" \
            --body "$(cat <<EOF
## Summary
${summary}

## Multi-Swarm Run
- Run ID: \`${RUN_ID}\`
- Swarm: #${swarm_num} of ${SWARM_COUNT}
- Branch: \`${branch}\`

---
Merged by streaming-merge pipeline
EOF
)" 2>&1) || {
            log_error "PR creation failed for swarm $swarm_num"
            git checkout "$BASE_BRANCH" 2>/dev/null || true
            update_result "$swarm_num" "error" "null" "PR creation failed"
            exit 1
        }

        log "PR created: $pr_url"

        # Step 4: Squash merge and delete branch
        log "Merging PR for swarm $swarm_num..."
        if ! gh pr merge --squash --delete-branch 2>&1; then
            log_error "PR merge failed for swarm $swarm_num"
            git checkout "$BASE_BRANCH" 2>/dev/null || true
            update_result "$swarm_num" "error" "$pr_url" "PR merge failed"
            exit 1
        fi

        # Step 5: Update base branch
        log "Updating base branch $BASE_BRANCH..."
        git checkout "$BASE_BRANCH" 2>&1
        git pull origin "$BASE_BRANCH" 2>&1

        update_result "$swarm_num" "merged" "$pr_url"
        log "Swarm $swarm_num merged successfully"
    ) || merge_exit=$?

    # Release lock
    flock -u 9
    exec 9>&-

    return $merge_exit
}

# ── Dependency Check ──────────────────────────────────────────────────

deps_satisfied() {
    local swarm_num="$1"
    local deps
    deps=$(jq -r ".swarms[$((swarm_num-1))].dependencies // [] | .[]" "$MANIFEST" 2>/dev/null || echo "")

    for dep in $deps; do
        if ! is_merged "$dep"; then
            return 1
        fi
    done
    return 0
}

# ── Main Loop ─────────────────────────────────────────────────────────

main() {
    log "=== Streaming Merge Pipeline ==="
    log "Run ID:      $RUN_ID"
    log "Base Branch: $BASE_BRANCH"
    log "Swarms:      $SWARM_COUNT"
    log "Manifest:    $MANIFEST"
    log "Poll:        ${POLL_INTERVAL}s"
    log "==============================="

    mkdir -p "$STATE_DIR"
    init_results

    local merge_order
    merge_order=$(get_merge_order)
    log "Merge order: $merge_order"

    while true; do
        if [ "$SHUTDOWN" -eq 1 ]; then
            log "Shutting down gracefully..."
            break
        fi

        local count
        count=$(processed_count)
        if [ "$count" -ge "$SWARM_COUNT" ]; then
            log "All $SWARM_COUNT swarms processed"
            break
        fi

        # Scan for newly completed swarms in merge order
        for swarm_num in $merge_order; do
            if [ "$SHUTDOWN" -eq 1 ]; then
                break
            fi

            # Skip already processed
            if is_merged "$swarm_num"; then
                continue
            fi

            local phase
            phase=$(swarm_phase "$swarm_num")

            # Handle terminal states
            if [ "$phase" = "error" ]; then
                log "Swarm $swarm_num is in error state, marking as processed"
                update_result "$swarm_num" "errored" "null" "Swarm failed"
                mark_merged "$swarm_num"
                continue
            fi

            # Only merge swarms that are done
            if [ "$phase" != "done" ]; then
                continue
            fi

            # Check dependency ordering
            if ! deps_satisfied "$swarm_num"; then
                log "Swarm $swarm_num is done but waiting on dependencies"
                continue
            fi

            log "Swarm $swarm_num completed — beginning merge"

            if merge_swarm "$swarm_num"; then
                mark_merged "$swarm_num"
                log "Swarm $swarm_num merged ($(processed_count)/$SWARM_COUNT)"
            else
                mark_merged "$swarm_num"
                log_error "Swarm $swarm_num merge failed ($(processed_count)/$SWARM_COUNT)"
            fi
        done

        # Check if all processed
        count=$(processed_count)
        if [ "$count" -ge "$SWARM_COUNT" ]; then
            break
        fi

        # Poll interval
        sleep "$POLL_INTERVAL"
    done

    finalize_results

    # Print summary
    log ""
    log "=== Streaming Merge Summary ==="
    local merged errored conflicted
    merged=$(jq '[.swarms[] | select(.status == "merged")] | length' "$RESULTS_FILE" 2>/dev/null || echo "0")
    errored=$(jq '[.swarms[] | select(.status == "errored" or .status == "error")] | length' "$RESULTS_FILE" 2>/dev/null || echo "0")
    conflicted=$(jq '[.swarms[] | select(.status == "conflict")] | length' "$RESULTS_FILE" 2>/dev/null || echo "0")
    log "Merged:     $merged"
    log "Conflicted: $conflicted"
    log "Errored:    $errored"
    log "Results:    $RESULTS_FILE"
    log "==============================="

    # Exit with error if any swarm failed
    if [ "$errored" -gt 0 ] || [ "$conflicted" -gt 0 ]; then
        exit 1
    fi
}

main
