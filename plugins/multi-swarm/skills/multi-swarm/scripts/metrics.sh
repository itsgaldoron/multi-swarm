#!/usr/bin/env bash
set -euo pipefail

# Multi-Swarm Metrics Collector & Aggregator
# Usage: metrics.sh <collect|summary|json> <run-id>
# Collects token usage, cost, phase timing, commit rate per swarm

COMMAND="${1:-}"
RUN_ID="${2:-}"

show_usage() {
    echo "Usage: metrics.sh <collect|summary|json> <run-id>"
    echo ""
    echo "Commands:"
    echo "  collect  Collect metrics for each swarm and write metrics.json files"
    echo "  summary  Print a human-readable summary of all metrics"
    echo "  json     Output all metrics as JSON (for dashboard consumption)"
    echo ""
    echo "Options:"
    echo "  -h, --help  Show this help message"
}

if [ "$COMMAND" = "-h" ] || [ "$COMMAND" = "--help" ]; then
    show_usage
    exit 0
fi

if [ -z "$COMMAND" ] || [ -z "$RUN_ID" ]; then
    show_usage
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "[metrics] ERROR: jq is required but not found" >&2
    exit 1
fi

log_error() { echo "[metrics] ERROR: $*" >&2; }

STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
GATEWAY_LOG="$HOME/.claude/multi-swarm/gateway.log"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)")"

if [ ! -d "$STATE_DIR/swarms" ]; then
    log_error "No state found for run $RUN_ID"
    echo "Expected: $STATE_DIR/swarms/"
    exit 1
fi

# ── Pricing (USD per million tokens) ──────────────────────────────
# All agents use Opus for maximum performance
get_pricing() {
    echo "15.00 75.00"
}

# ── Token Parsing ─────────────────────────────────────────────────
# Parse gateway logs for token usage per swarm
# LiteLLM logs contain usage info: "Usage: prompt_tokens=X, completion_tokens=Y"
collect_tokens() {
    local swarm_id="$1"
    local input_tokens=0
    local output_tokens=0

    if [ -f "$GATEWAY_LOG" ]; then
        # LiteLLM logs token usage in various formats; extract what we can
        # Look for lines referencing this swarm's token or general usage
        input_tokens=$(grep -i "prompt_tokens" "$GATEWAY_LOG" 2>/dev/null \
            | grep -oE "prompt_tokens[\"= :]+[0-9]+" \
            | grep -oE "[0-9]+" \
            | awk '{s+=$1} END {print s+0}' || echo "0")
        output_tokens=$(grep -i "completion_tokens" "$GATEWAY_LOG" 2>/dev/null \
            | grep -oE "completion_tokens[\"= :]+[0-9]+" \
            | grep -oE "[0-9]+" \
            | awk '{s+=$1} END {print s+0}' || echo "0")

        # Divide evenly across swarms as gateway logs aren't per-swarm
        local swarm_count
        swarm_count=$(find "$STATE_DIR/swarms" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
        if [ "$swarm_count" -gt 1 ]; then
            input_tokens=$((input_tokens / swarm_count))
            output_tokens=$((output_tokens / swarm_count))
        fi
    fi

    echo "$input_tokens $output_tokens"
}

# ── Cost Calculation ──────────────────────────────────────────────
calculate_cost() {
    local input_tokens="$1"
    local output_tokens="$2"
    local model="${3:-opus}"

    local pricing
    pricing=$(get_pricing "$model")
    local input_price output_price
    input_price=$(echo "$pricing" | awk '{print $1}')
    output_price=$(echo "$pricing" | awk '{print $2}')

    # Cost = tokens * price_per_million / 1,000,000
    local input_cost output_cost total_cost
    input_cost=$(awk "BEGIN {printf \"%.6f\", $input_tokens * $input_price / 1000000}")
    output_cost=$(awk "BEGIN {printf \"%.6f\", $output_tokens * $output_price / 1000000}")
    total_cost=$(awk "BEGIN {printf \"%.6f\", $input_cost + $output_cost}")

    echo "$input_cost $output_cost $total_cost"
}

# ── Phase Timing ──────────────────────────────────────────────────
# Read status.json and calculate phase durations
collect_phases() {
    local status_file="$1"

    if [ ! -f "$status_file" ]; then
        echo "{}"
        return
    fi

    local started_at updated_at phase
    started_at=$(jq -r '.startedAt // empty' "$status_file" 2>/dev/null || echo "")
    updated_at=$(jq -r '.updatedAt // empty' "$status_file" 2>/dev/null || echo "")
    phase=$(jq -r '.phase // "unknown"' "$status_file" 2>/dev/null || echo "unknown")

    if [ -z "$started_at" ]; then
        echo "{}"
        return
    fi

    # Calculate total elapsed seconds
    local start_epoch now_epoch elapsed
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || \
                  date -d "$started_at" +%s 2>/dev/null || echo "0")
    if [ -n "$updated_at" ]; then
        now_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || \
                    date -d "$updated_at" +%s 2>/dev/null || date +%s)
    else
        now_epoch=$(date +%s)
    fi

    if [ "$start_epoch" -eq 0 ]; then
        echo "{}"
        return
    fi

    elapsed=$((now_epoch - start_epoch))

    # Output phase info as JSON
    jq -n --arg phase "$phase" \
          --arg startedAt "$started_at" \
          --argjson duration "$elapsed" \
        '{
            ($phase): {
                "startedAt": $startedAt,
                "duration": $duration
            }
        }'
}

# ── Commit Analysis ───────────────────────────────────────────────
collect_commits() {
    local swarm_id="$1"
    local status_file="$2"

    local branch_name
    branch_name=$(jq -r '.branch // empty' "$status_file" 2>/dev/null || echo "")

    # Try to find the branch from the run state
    if [ -z "$branch_name" ]; then
        # Guess branch name from convention: swarm/{run-id}/{swarm-number}-*
        local swarm_num="${swarm_id#swarm-}"
        branch_name=$(git branch -a 2>/dev/null | grep "swarm/${RUN_ID}/${swarm_num}" | head -1 | tr -d ' *' || echo "")
    fi

    local commit_count=0
    local rate=0.0

    if [ -n "$branch_name" ]; then
        # Count commits on this branch since it diverged from base
        commit_count=$(git log --oneline "$branch_name" --not main 2>/dev/null | wc -l | tr -d ' ' || echo "0")

        # Calculate rate (commits per minute)
        local started_at elapsed_min
        started_at=$(jq -r '.startedAt // empty' "$status_file" 2>/dev/null || echo "")
        if [ -n "$started_at" ]; then
            local start_epoch now_epoch
            start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || \
                          date -d "$started_at" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            elapsed_min=$(( (now_epoch - start_epoch) / 60 ))
            if [ "$elapsed_min" -gt 0 ]; then
                rate=$(awk "BEGIN {printf \"%.2f\", $commit_count / $elapsed_min}")
            fi
        fi
    else
        # Fallback: read commit count from status.json
        commit_count=$(jq -r '.commits // 0' "$status_file" 2>/dev/null || echo "0")
    fi

    echo "$commit_count $rate"
}

# ── Files Changed ─────────────────────────────────────────────────
collect_files_changed() {
    local swarm_id="$1"
    local status_file="$2"

    local swarm_num="${swarm_id#swarm-}"
    local branch_name
    branch_name=$(git branch -a 2>/dev/null | grep "swarm/${RUN_ID}/${swarm_num}" | head -1 | tr -d ' *' || echo "")

    if [ -n "$branch_name" ]; then
        git diff --name-only main..."$branch_name" 2>/dev/null | wc -l | tr -d ' ' || echo "0"
    else
        local files_arr
        files_arr=$(jq -r '.filesChanged // [] | length' "$status_file" 2>/dev/null || echo "0")
        echo "$files_arr"
    fi
}

# ── Collect Metrics for One Swarm ─────────────────────────────────
collect_swarm_metrics() {
    local swarm_dir="$1"
    local swarm_id
    swarm_id=$(basename "$swarm_dir")
    local swarm_num="${swarm_id#swarm-}"
    local status_file="$swarm_dir/status.json"
    local metrics_file="$swarm_dir/metrics.json"

    if [ ! -f "$status_file" ]; then
        echo "  Skipping $swarm_id (no status.json)"
        return
    fi

    # Collect all metrics
    local tokens_raw costs_raw commits_raw files_changed phases_json
    tokens_raw=$(collect_tokens "$swarm_id")
    local input_tokens output_tokens
    input_tokens=$(echo "$tokens_raw" | awk '{print $1}')
    output_tokens=$(echo "$tokens_raw" | awk '{print $2}')
    local total_tokens=$((input_tokens + output_tokens))

    costs_raw=$(calculate_cost "$input_tokens" "$output_tokens")
    local input_cost output_cost total_cost
    input_cost=$(echo "$costs_raw" | awk '{print $1}')
    output_cost=$(echo "$costs_raw" | awk '{print $2}')
    total_cost=$(echo "$costs_raw" | awk '{print $3}')

    phases_json=$(collect_phases "$status_file")

    commits_raw=$(collect_commits "$swarm_id" "$status_file")
    local commit_count commit_rate
    commit_count=$(echo "$commits_raw" | awk '{print $1}')
    commit_rate=$(echo "$commits_raw" | awk '{print $2}')

    files_changed=$(collect_files_changed "$swarm_id" "$status_file")

    local collected_at
    collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Write metrics.json
    jq -n \
        --argjson swarmId "$swarm_num" \
        --argjson inputTokens "$input_tokens" \
        --argjson outputTokens "$output_tokens" \
        --argjson totalTokens "$total_tokens" \
        --argjson inputCost "$input_cost" \
        --argjson outputCost "$output_cost" \
        --argjson totalCost "$total_cost" \
        --argjson phases "$phases_json" \
        --argjson commitCount "$commit_count" \
        --argjson commitRate "$commit_rate" \
        --argjson filesChanged "$files_changed" \
        --arg collectedAt "$collected_at" \
        '{
            "swarmId": $swarmId,
            "tokens": {
                "input": $inputTokens,
                "output": $outputTokens,
                "total": $totalTokens
            },
            "cost": {
                "input": $inputCost,
                "output": $outputCost,
                "total": $totalCost
            },
            "phases": $phases,
            "commits": {
                "count": $commitCount,
                "rate": $commitRate
            },
            "filesChanged": $filesChanged,
            "collectedAt": $collectedAt
        }' > "$metrics_file"

    echo "  Collected metrics for $swarm_id -> $metrics_file"
}

# ── Commands ──────────────────────────────────────────────────────

cmd_collect() {
    echo "Collecting metrics for run $RUN_ID..."
    echo ""

    for swarm_dir in "$STATE_DIR"/swarms/swarm-*; do
        [ -d "$swarm_dir" ] || continue
        collect_swarm_metrics "$swarm_dir"
    done

    echo ""
    echo "Done. Run 'metrics.sh summary $RUN_ID' to view results."
}

cmd_summary() {
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║           Multi-Swarm Metrics Summary               ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "  Run: $RUN_ID"
    echo ""

    local total_input=0 total_output=0 total_cost_all=0
    local total_commits=0 total_files=0 swarm_count=0

    printf "  %-8s %-12s %-12s %-10s %-8s %-8s\n" \
        "SWARM" "IN TOKENS" "OUT TOKENS" "COST" "COMMITS" "FILES"
    printf "  %-8s %-12s %-12s %-10s %-8s %-8s\n" \
        "-----" "---------" "----------" "----" "-------" "-----"

    for swarm_dir in "$STATE_DIR"/swarms/swarm-*; do
        [ -d "$swarm_dir" ] || continue
        local metrics_file="$swarm_dir/metrics.json"
        local swarm_id
        swarm_id=$(basename "$swarm_dir")

        if [ ! -f "$metrics_file" ]; then
            printf "  %-8s %-12s %-12s %-10s %-8s %-8s\n" \
                "$swarm_id" "—" "—" "—" "—" "—"
            continue
        fi

        local in_tok out_tok cost commits files
        in_tok=$(jq -r '.tokens.input // 0' "$metrics_file")
        out_tok=$(jq -r '.tokens.output // 0' "$metrics_file")
        cost=$(jq -r '.cost.total // 0' "$metrics_file")
        commits=$(jq -r '.commits.count // 0' "$metrics_file")
        files=$(jq -r '.filesChanged // 0' "$metrics_file")

        # Format cost with dollar sign
        local cost_fmt
        cost_fmt=$(awk "BEGIN {printf \"\$%.2f\", $cost}")

        printf "  %-8s %-12s %-12s %-10s %-8s %-8s\n" \
            "$swarm_id" "$in_tok" "$out_tok" "$cost_fmt" "$commits" "$files"

        total_input=$((total_input + in_tok))
        total_output=$((total_output + out_tok))
        total_cost_all=$(awk "BEGIN {printf \"%.6f\", $total_cost_all + $cost}")
        total_commits=$((total_commits + commits))
        total_files=$((total_files + files))
        swarm_count=$((swarm_count + 1))
    done

    echo ""
    echo "── Totals ───────────────────────────────────────────"
    echo "  Swarms:         $swarm_count"
    echo "  Input Tokens:   $total_input"
    echo "  Output Tokens:  $total_output"
    echo "  Total Tokens:   $((total_input + total_output))"
    local total_cost_fmt
    total_cost_fmt=$(awk "BEGIN {printf \"\$%.2f\", $total_cost_all}")
    echo "  Total Cost:     $total_cost_fmt"
    echo "  Total Commits:  $total_commits"
    echo "  Total Files:    $total_files"

    # Phase summary from status.json files
    echo ""
    echo "── Phase Distribution ───────────────────────────────"
    local phases_list=""
    for swarm_dir in "$STATE_DIR"/swarms/swarm-*; do
        [ -d "$swarm_dir" ] || continue
        local status_file="$swarm_dir/status.json"
        [ -f "$status_file" ] || continue
        local phase
        phase=$(jq -r '.phase // "unknown"' "$status_file" 2>/dev/null)
        phases_list="${phases_list}${phase}\n"
    done
    if [ -n "$phases_list" ]; then
        echo -e "$phases_list" | sort | uniq -c | sort -rn | while read -r count phase; do
            [ -z "$phase" ] && continue
            printf "  %-20s %s\n" "$phase" "$count swarm(s)"
        done
    fi

    echo ""
    echo "╚══════════════════════════════════════════════════════╝"
}

cmd_json() {
    local swarm_metrics=()

    for swarm_dir in "$STATE_DIR"/swarms/swarm-*; do
        [ -d "$swarm_dir" ] || continue
        local metrics_file="$swarm_dir/metrics.json"

        if [ -f "$metrics_file" ]; then
            swarm_metrics+=("$(cat "$metrics_file")")
        fi
    done

    # Build aggregate totals
    local total_input=0 total_output=0 total_cost=0
    local total_commits=0 total_files=0

    for swarm_dir in "$STATE_DIR"/swarms/swarm-*; do
        [ -d "$swarm_dir" ] || continue
        local metrics_file="$swarm_dir/metrics.json"
        [ -f "$metrics_file" ] || continue

        total_input=$((total_input + $(jq -r '.tokens.input // 0' "$metrics_file")))
        total_output=$((total_output + $(jq -r '.tokens.output // 0' "$metrics_file")))
        total_cost=$(awk "BEGIN {printf \"%.6f\", $total_cost + $(jq -r '.cost.total // 0' "$metrics_file")}")
        total_commits=$((total_commits + $(jq -r '.commits.count // 0' "$metrics_file")))
        total_files=$((total_files + $(jq -r '.filesChanged // 0' "$metrics_file")))
    done

    # Combine all swarm metrics into a JSON array, then wrap with aggregate
    local swarms_json="[]"
    if [ ${#swarm_metrics[@]} -gt 0 ]; then
        swarms_json=$(printf '%s\n' "${swarm_metrics[@]}" | jq -s '.')
    fi

    jq -n \
        --arg runId "$RUN_ID" \
        --argjson swarms "$swarms_json" \
        --argjson totalInput "$total_input" \
        --argjson totalOutput "$total_output" \
        --argjson totalCost "$total_cost" \
        --argjson totalCommits "$total_commits" \
        --argjson totalFiles "$total_files" \
        --arg collectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            "runId": $runId,
            "swarms": $swarms,
            "aggregate": {
                "tokens": {
                    "input": $totalInput,
                    "output": $totalOutput,
                    "total": ($totalInput + $totalOutput)
                },
                "cost": {
                    "total": $totalCost
                },
                "commits": $totalCommits,
                "filesChanged": $totalFiles
            },
            "collectedAt": $collectedAt
        }'
}

# ── Dispatch ──────────────────────────────────────────────────────
case "$COMMAND" in
    collect) cmd_collect ;;
    summary) cmd_summary ;;
    json)    cmd_json ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Usage: metrics.sh <collect|summary|json> <run-id>"
        exit 1
        ;;
esac
