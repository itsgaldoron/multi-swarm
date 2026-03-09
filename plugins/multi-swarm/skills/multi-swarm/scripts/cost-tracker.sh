#!/usr/bin/env bash
# Multi-Swarm Cost Tracker
# Tracks and reports API usage costs.
# Both sourceable (for functions) and executable (for CLI usage).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-router.sh"

# --- Utilities ---
log_error() { echo "[cost-tracker] ERROR: $*" >&2; }
_require_jq() { command -v jq &>/dev/null || { log_error "jq is required"; return 1; }; }

# --- State paths ---
_cost_tracker_log() {
    local run_id="${RUN_ID:-${1:-default}}"
    local state_dir="$HOME/.claude/multi-swarm/state/${run_id}"
    mkdir -p "$state_dir"
    echo "$state_dir/cost-tracking.jsonl"
}

# --- Core functions ---

# Append a usage record to the tracking log.
# Usage: track_usage ROLE INPUT_TOKENS OUTPUT_TOKENS [SWARM_ID] [RUN_ID]
track_usage() {
    local role="${1:?Usage: track_usage <role> <input_tokens> <output_tokens> [swarm_id] [run_id]}"
    local input_tokens="${2:?Missing input_tokens}"
    local output_tokens="${3:?Missing output_tokens}"
    local swarm_id="${4:-0}"

    if ! [[ "$input_tokens" =~ ^[0-9]+$ ]]; then log_error "input_tokens must be a non-negative integer, got: $input_tokens"; return 1; fi
    if ! [[ "$output_tokens" =~ ^[0-9]+$ ]]; then log_error "output_tokens must be a non-negative integer, got: $output_tokens"; return 1; fi
    if ! [[ "$swarm_id" =~ ^[0-9]+$ ]]; then log_error "swarm_id must be a non-negative integer, got: $swarm_id"; return 1; fi
    local run_id="${5:-${RUN_ID:-default}}"

    local tier model input_cost output_cost total_cost
    tier=$(get_model_tier "$role")
    model=$(get_model_for_role "$role")

    # Compute costs (tokens / 1M * cost_per_1M) using awk for floating point
    input_cost=$(awk "BEGIN {printf \"%.6f\", $input_tokens / 1000000 * $OPUS_INPUT_COST}")
    output_cost=$(awk "BEGIN {printf \"%.6f\", $output_tokens / 1000000 * $OPUS_OUTPUT_COST}")
    total_cost=$(awk "BEGIN {printf \"%.6f\", $input_cost + $output_cost}")

    local log_file
    log_file=$(_cost_tracker_log "$run_id")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    printf '{"timestamp":"%s","swarm_id":%d,"role":"%s","model":"%s","tier":"%s","input_tokens":%d,"output_tokens":%d,"input_cost":%s,"output_cost":%s,"total_cost":%s}\n' \
        "$timestamp" "$swarm_id" "$role" "$model" "$tier" \
        "$input_tokens" "$output_tokens" "$input_cost" "$output_cost" "$total_cost" \
        >> "$log_file"
}

# Print a formatted cost summary table.
# Usage: get_cost_summary [RUN_ID]
get_cost_summary() {
    _require_jq || return 1
    local run_id="${1:-${RUN_ID:-default}}"
    local log_file
    log_file=$(_cost_tracker_log "$run_id")

    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        echo "  No usage data recorded yet."
        return 0
    fi

    echo "  ── Cost by Model Tier ──────────────────────────────"
    printf "  %-18s %12s %12s %10s\n" "MODEL" "INPUT TOKENS" "OUTPUT TOKENS" "COST"
    printf "  %-18s %12s %12s %10s\n" "─────" "────────────" "─────────────" "────"

    local grand_total=0

    for tier in opus; do
        local model_name input_sum output_sum cost_sum
        model_name="$TIER_OPUS"

        # Aggregate from log using jq
        local agg
        agg=$(jq -s --arg t "$tier" '
            [.[] | select(.tier == $t)] |
            {input: (map(.input_tokens) | add // 0),
             output: (map(.output_tokens) | add // 0),
             cost: (map(.total_cost) | add // 0)}
        ' "$log_file" 2>/dev/null)

        input_sum=$(echo "$agg" | jq -r '.input')
        output_sum=$(echo "$agg" | jq -r '.output')
        cost_sum=$(echo "$agg" | jq -r '.cost')

        # Skip tiers with no usage
        if [ "$input_sum" = "0" ] && [ "$output_sum" = "0" ]; then
            continue
        fi

        local cost_fmt
        cost_fmt=$(awk "BEGIN {printf \"$%.4f\", $cost_sum}")
        printf "  %-18s %12d %12d %10s\n" "$tier" "$input_sum" "$output_sum" "$cost_fmt"
        grand_total=$(awk "BEGIN {printf \"%.6f\", $grand_total + $cost_sum}")
    done

    echo ""
    local grand_fmt
    grand_fmt=$(awk "BEGIN {printf \"$%.4f\", $grand_total}")
    printf "  %-44s %10s\n" "TOTAL" "$grand_fmt"
}

# Print total cost summary.
# Usage: get_savings [RUN_ID]
get_savings() {
    _require_jq || return 1
    local run_id="${1:-${RUN_ID:-default}}"
    local log_file
    log_file=$(_cost_tracker_log "$run_id")

    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        return 0
    fi

    local total_cost
    total_cost=$(jq -s 'map(.total_cost) | add // 0' "$log_file" 2>/dev/null)
    printf "  Total run cost:   \$%.4f\n" "$total_cost"
}

# Print cost breakdown for a specific swarm.
# Usage: get_cost_for_swarm SWARM_ID [RUN_ID]
get_cost_for_swarm() {
    _require_jq || return 1
    local swarm_id="${1:?Usage: get_cost_for_swarm <swarm_id> [run_id]}"
    local run_id="${2:-${RUN_ID:-default}}"
    local log_file
    log_file=$(_cost_tracker_log "$run_id")

    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        echo "  No usage data for swarm $swarm_id."
        return 0
    fi

    echo "  ── Swarm #${swarm_id} Cost Breakdown ─────────────────"
    printf "  %-20s %-8s %12s %12s %10s\n" "ROLE" "TIER" "INPUT" "OUTPUT" "COST"
    printf "  %-20s %-8s %12s %12s %10s\n" "────" "────" "─────" "──────" "────"

    local swarm_total=0
    jq -c --argjson sid "$swarm_id" 'select(.swarm_id == $sid)' "$log_file" 2>/dev/null | while IFS= read -r line; do
        local role tier input_t output_t cost
        role=$(echo "$line" | jq -r '.role')
        tier=$(echo "$line" | jq -r '.tier')
        input_t=$(echo "$line" | jq -r '.input_tokens')
        output_t=$(echo "$line" | jq -r '.output_tokens')
        cost=$(echo "$line" | jq -r '.total_cost')
        local cost_fmt
        cost_fmt=$(awk "BEGIN {printf \"$%.4f\", $cost}")
        printf "  %-20s %-8s %12d %12d %10s\n" "$role" "$tier" "$input_t" "$output_t" "$cost_fmt"
    done

    local total
    total=$(jq -s --argjson sid "$swarm_id" '
        [.[] | select(.swarm_id == $sid)] | map(.total_cost) | add // 0
    ' "$log_file" 2>/dev/null)
    echo ""
    printf "  Swarm #%d total: \$%.4f\n" "$swarm_id" "$total"
}

# Clear the tracking log.
# Usage: reset_tracking [RUN_ID]
reset_tracking() {
    local run_id="${1:-${RUN_ID:-default}}"
    local log_file
    log_file=$(_cost_tracker_log "$run_id")
    if [ -f "$log_file" ]; then
        rm "$log_file"
        echo "  Cost tracking log reset for run: $run_id"
    else
        echo "  No log to reset for run: $run_id"
    fi
}

# --- CLI mode ---
_cost_tracker_cli() {
    _require_jq || exit 1
    case "${1:-}" in
        track)
            shift
            track_usage "$@"
            echo "Usage recorded."
            ;;
        summary)
            get_cost_summary "${2:-}"
            ;;
        savings)
            get_savings "${2:-}"
            ;;
        swarm)
            get_cost_for_swarm "${2:?Usage: cost-tracker.sh swarm <swarm_id> [run_id]}" "${3:-}"
            ;;
        reset)
            reset_tracking "${2:-}"
            ;;
        --help|-h|"")
            echo "Usage: cost-tracker.sh <command> [args]"
            echo ""
            echo "Track and report API usage costs."
            echo ""
            echo "Commands:"
            echo "  track <role> <input_tokens> <output_tokens> [swarm_id] [run_id]"
            echo "                         Record token usage for an agent role"
            echo "  summary [run_id]       Show cost breakdown"
            echo "  savings [run_id]       Show total run cost"
            echo "  swarm <id> [run_id]    Show cost breakdown for a specific swarm"
            echo "  reset [run_id]         Clear the tracking log"
            echo "  --help                 Show this help message"
            ;;
        *)
            echo "Unknown command: $1 (try --help)" >&2
            exit 1
            ;;
    esac
}

# Run CLI only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    _cost_tracker_cli "$@"
fi
