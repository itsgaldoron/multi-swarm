#!/usr/bin/env bash
set -euo pipefail

# Multi-Swarm Monitor
# Usage: monitor.sh [run-id] [options]
# Shows status dashboard for active swarms
#
# Options:
#   (no flags)             One-shot status display (original behavior)
#   -w, --watch            Continuous refresh mode
#   -b, --background       Start background monitoring (writes to log file)
#   -i, --interval SECS    Refresh interval in seconds (default: 5)
#   --status               Check if background monitor is running
#   --stop                 Stop background monitor
#   -h, --help             Show this help message

# ── ANSI Color Definitions ──────────────────────────────────────────
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "1" ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_BLUE="\033[34m"
    C_CYAN="\033[36m"
    C_MAGENTA="\033[35m"
    C_WHITE="\033[37m"
    C_BG_RED="\033[41m"
    C_BG_GREEN="\033[42m"
    C_BG_YELLOW="\033[43m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE=""
    C_CYAN="" C_MAGENTA="" C_WHITE="" C_BG_RED="" C_BG_GREEN="" C_BG_YELLOW=""
fi

# ── Argument Parsing ────────────────────────────────────────────────
RUN_ID=""
WATCH_MODE=false
BACKGROUND_MODE=false
INTERVAL=5
CHECK_STATUS=false
STOP_BACKGROUND=false
SHOW_HELP=false

while [ $# -gt 0 ]; do
    case "$1" in
        -w|--watch)
            WATCH_MODE=true
            shift
            ;;
        -b|--background)
            BACKGROUND_MODE=true
            shift
            ;;
        -i|--interval)
            if [ $# -lt 2 ]; then
                echo "Error: --interval requires a value" >&2
                exit 1
            fi
            INTERVAL="$2"
            shift 2
            ;;
        --status)
            CHECK_STATUS=true
            shift
            ;;
        --stop)
            STOP_BACKGROUND=true
            shift
            ;;
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            RUN_ID="$1"
            shift
            ;;
    esac
done

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not found" >&2
    exit 1
fi

# Log helper
log_error() { echo "[monitor] ERROR: $*" >&2; }

GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"
GATEWAY_PORT=$(jq -r '.gateway.port // 4000' "$GLOBAL_CONFIG" 2>/dev/null || echo "4000")
MASTER_KEY=$(jq -r '.gateway.masterKey // "ms-gateway-key"' "$GLOBAL_CONFIG" 2>/dev/null || echo "ms-gateway-key")
PID_DIR="$HOME/.claude/multi-swarm/monitor"

# ── Help ────────────────────────────────────────────────────────────
show_help() {
    cat <<'HELP'
Multi-Swarm Monitor — Real-time status dashboard for swarm runs

Usage:
  monitor.sh [run-id]                  One-shot status display
  monitor.sh [run-id] --watch          Continuous refresh (default 5s)
  monitor.sh [run-id] --watch -i 10    Refresh every 10 seconds
  monitor.sh [run-id] --background     Start background monitoring
  monitor.sh --status                  Check background monitor status
  monitor.sh --stop                    Stop background monitor

Options:
  -w, --watch            Continuous refresh mode (q=quit, r=refresh)
  -b, --background       Run monitor in background, log to file
  -i, --interval SECS    Refresh interval in seconds (default: 5)
  --status               Show background monitor status
  --stop                 Stop the background monitor
  -h, --help             Show this help message
HELP
}

if $SHOW_HELP; then
    show_help
    exit 0
fi

# ── Utility Functions ───────────────────────────────────────────────

# Colorize status text based on value
colorize_status() {
    local status="$1"
    case "$status" in
        done|completed|complete|healthy|HEALTHY)
            printf "${C_GREEN}%s${C_RESET}" "$status" ;;
        working|running|in_progress|analyzing|coding)
            printf "${C_YELLOW}%s${C_RESET}" "$status" ;;
        error|failed|ERROR|FAILED|DOWN)
            printf "${C_RED}${C_BOLD}%s${C_RESET}" "$status" ;;
        pending|waiting|queued)
            printf "${C_BLUE}%s${C_RESET}" "$status" ;;
        merging|reviewing)
            printf "${C_MAGENTA}%s${C_RESET}" "$status" ;;
        *)
            printf "%s" "$status" ;;
    esac
}

# Draw a progress bar: progress_bar <current> <total> <width>
progress_bar() {
    local current="${1:-0}" total="${2:-1}" width="${3:-20}"
    # Validate numeric before arithmetic
    [[ "$current" =~ ^[0-9]+$ ]] || current=0
    [[ "$total" =~ ^[0-9]+$ ]] || total=1
    [ "$total" -eq 0 ] && total=1
    local pct=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    printf "${C_GREEN}"
    for ((i=0; i<filled; i++)); do printf "█"; done
    printf "${C_DIM}"
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "${C_RESET} %3d%%" "$pct"
}

# Get terminal width (fallback to 60)
term_width() {
    tput cols 2>/dev/null || echo 60
}

# Draw a horizontal rule that fits the terminal
hr() {
    local label="${1:-}" width
    width=$(term_width)
    if [ -n "$label" ]; then
        local label_len=${#label}
        local pad=$(( width - label_len - 4 ))
        [ "$pad" -lt 0 ] && pad=0
        printf "── %s " "$label"
        printf '%*s\n' "$pad" '' | tr ' ' '─'
    else
        printf '%*s\n' "$width" '' | tr ' ' '─'
    fi
}

# ── Background Monitor Functions ────────────────────────────────────

get_pid_file() {
    echo "$PID_DIR/monitor.pid"
}

get_log_file() {
    local rid="${1:-default}"
    echo "$PID_DIR/${rid}.log"
}

start_background() {
    mkdir -p "$PID_DIR"
    local pid_file
    pid_file=$(get_pid_file)

    # Check if already running
    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo -e "${C_YELLOW}Background monitor already running (PID $old_pid)${C_RESET}"
            echo "  Use 'monitor.sh --stop' to stop it first."
            exit 1
        else
            rm -f "$pid_file"
        fi
    fi

    local log_file
    log_file=$(get_log_file "${RUN_ID:-default}")

    echo -e "${C_GREEN}Starting background monitor...${C_RESET}"
    echo "  Log file: $log_file"
    echo "  Interval: ${INTERVAL}s"
    echo "  Check status: monitor.sh --status"
    echo "  Stop:         monitor.sh --stop"

    # Launch background process
    (
        FORCE_COLOR=0
        while true; do
            {
                echo "=== Monitor snapshot at $(date '+%Y-%m-%d %H:%M:%S') ==="
                render_dashboard
                echo ""
            } >> "$log_file" 2>&1
            sleep "$INTERVAL"
        done
    ) &
    local bg_pid=$!
    echo "$bg_pid" > "$pid_file"
    echo -e "${C_GREEN}Background monitor started (PID $bg_pid)${C_RESET}"
}

check_background_status() {
    local pid_file
    pid_file=$(get_pid_file)
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${C_GREEN}●${C_RESET} Background monitor is ${C_GREEN}running${C_RESET} (PID $pid)"
            # Show latest log file
            local log_file
            log_file=$(find "$PID_DIR" -name "*.log" -newer "$pid_file" -o -name "*.log" 2>/dev/null | head -1)
            if [ -z "$log_file" ]; then
                log_file=$(find "$PID_DIR" -name "*.log" 2>/dev/null | head -1)
            fi
            if [ -n "$log_file" ] && [ -f "$log_file" ]; then
                echo "  Log: $log_file"
                echo "  Size: $(du -h "$log_file" | cut -f1)"
                echo ""
                echo -e "${C_DIM}── Last snapshot ──${C_RESET}"
                # Show last snapshot
                awk '/^=== Monitor snapshot/{buf=""; capture=1} capture{buf=buf $0 "\n"} END{printf "%s", buf}' "$log_file"
            fi
        else
            echo -e "${C_RED}●${C_RESET} Background monitor is ${C_RED}not running${C_RESET} (stale PID $pid)"
            rm -f "$pid_file"
        fi
    else
        echo -e "${C_DIM}●${C_RESET} No background monitor is running"
    fi
}

stop_background() {
    local pid_file
    pid_file=$(get_pid_file)
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            # Wait briefly for process to exit
            for ((i=0; i<10; i++)); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            rm -f "$pid_file"
            echo -e "${C_GREEN}Background monitor stopped (PID $pid)${C_RESET}"
        else
            rm -f "$pid_file"
            echo -e "${C_YELLOW}Background monitor was not running (stale PID removed)${C_RESET}"
        fi
    else
        echo "No background monitor is running."
    fi
}

# ── Dashboard Rendering ────────────────────────────────────────────

render_dashboard() {
    local width
    width=$(term_width)
    local border_len=56
    local ts
    ts=$(date '+%H:%M:%S')

    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║           Multi-Swarm Status Dashboard              ║${C_RESET}"
    echo -e "${C_BOLD}╠══════════════════════════════════════════════════════╣${C_RESET}"
    if $WATCH_MODE; then
        printf  "${C_DIM}  Refreshing every %ds │ %s │ q=quit r=refresh${C_RESET}\n" "$INTERVAL" "$ts"
    fi
    echo ""

    # ── Gateway Status ──
    hr "Gateway"
    if curl -sf -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
        echo -e "  Status: $(colorize_status "HEALTHY") (port $GATEWAY_PORT)"
        # Try to get model info
        local health_json
        health_json=$(curl -sf -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${GATEWAY_PORT}/health" 2>/dev/null || echo "{}")
        local healthy_count unhealthy_count
        healthy_count=$(echo "$health_json" | jq '[.healthy_endpoints] | map(length) | .[0] // 0' 2>/dev/null || echo "?")
        unhealthy_count=$(echo "$health_json" | jq '[.unhealthy_endpoints] | map(length) | .[0] // 0' 2>/dev/null || echo "?")
        echo -e "  Endpoints: ${C_GREEN}${healthy_count} healthy${C_RESET}, ${C_RED}${unhealthy_count} unhealthy${C_RESET}"
    else
        echo -e "  Status: $(colorize_status "DOWN")"
    fi
    echo ""

    # ── Active Worktrees ──
    hr "Worktrees"
    if git worktree list 2>/dev/null | grep -v "^$" >/dev/null 2>&1; then
        git worktree list 2>/dev/null | while read -r line; do
            # Highlight swarm worktrees
            if echo "$line" | grep -q "swarm"; then
                echo -e "  ${C_CYAN}▸${C_RESET} $line"
            else
                echo -e "  ${C_DIM}▸${C_RESET} $line"
            fi
        done
    else
        echo -e "  ${C_DIM}No worktrees active${C_RESET}"
    fi
    echo ""

    # ── tmux Sessions ──
    hr "tmux Sessions"
    if command -v tmux &>/dev/null; then
        local sessions
        sessions=$(tmux list-sessions 2>/dev/null | grep "swarm" || echo "")
        if [ -n "$sessions" ]; then
            echo "$sessions" | while read -r line; do
                echo -e "  ${C_CYAN}▸${C_RESET} $line"
            done
        else
            echo -e "  ${C_DIM}No swarm sessions active${C_RESET}"
        fi
    else
        echo -e "  ${C_DIM}tmux not available${C_RESET}"
    fi
    echo ""

    # ── Agent Teams ──
    hr "Agent Teams"
    if [ -d "$HOME/.claude/teams" ]; then
        local team_found=false
        for team_config in "$HOME/.claude/teams"/*/config.json; do
            [ -f "$team_config" ] || continue
            team_found=true
            local team_name member_count
            team_name=$(jq -r '.name // "unknown"' "$team_config" 2>/dev/null)
            member_count=$(jq -r '.members | length // 0' "$team_config" 2>/dev/null)
            echo -e "  ${C_CYAN}▸${C_RESET} Team: ${C_BOLD}$team_name${C_RESET} ($member_count members)"
        done
        if ! $team_found; then
            echo -e "  ${C_DIM}No active teams${C_RESET}"
        fi
    else
        echo -e "  ${C_DIM}No active teams${C_RESET}"
    fi
    echo ""

    # ── Swarm Status (if run-id provided) ──
    if [ -n "$RUN_ID" ]; then
        local state_dir="$HOME/.claude/multi-swarm/state/${RUN_ID}"
        if [ -d "$state_dir/swarms" ]; then
            hr "Swarm Progress (Run: ${RUN_ID})"
            echo ""
            printf "  ${C_BOLD}%-8s %-12s %-15s %-10s %s${C_RESET}\n" "SWARM" "STATUS" "PHASE" "COMMITS" "PROGRESS"
            printf "  ${C_DIM}%-8s %-12s %-15s %-10s %s${C_RESET}\n" "─────" "──────" "─────" "───────" "────────"

            local total_swarms=0 done_count=0 error_count=0 has_errors=false

            for status_file in "$state_dir"/swarms/*/status.json; do
                [ -f "$status_file" ] || continue
                local swarm_dir swarm_name status phase commits progress
                swarm_dir=$(dirname "$status_file")
                swarm_name=$(basename "$swarm_dir")

                status=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null)
                phase=$(jq -r '.phase // "unknown"' "$status_file" 2>/dev/null)
                commits=$(jq -r '.commits // 0' "$status_file" 2>/dev/null)
                progress=$(jq -r '.progress // "N/A"' "$status_file" 2>/dev/null)

                total_swarms=$((total_swarms + 1))

                # Count done and errors
                case "$phase" in
                    done|completed|complete) done_count=$((done_count + 1)) ;;
                    error|failed) error_count=$((error_count + 1)); has_errors=true ;;
                esac

                # Format status with color
                local colored_status colored_phase
                colored_status=$(colorize_status "$status")
                colored_phase=$(colorize_status "$phase")

                # Build progress bar if progress is numeric like "3/5"
                local progress_display="$progress"
                if echo "$progress" | grep -qE '^[0-9]+/[0-9]+$'; then
                    local prog_current prog_total
                    prog_current=$(echo "$progress" | cut -d/ -f1)
                    prog_total=$(echo "$progress" | cut -d/ -f2)
                    progress_display=$(progress_bar "$prog_current" "$prog_total" 15)
                elif echo "$progress" | grep -qE '^[0-9]+%$'; then
                    local pct_val
                    pct_val=$(echo "$progress" | tr -d '%')
                    progress_display=$(progress_bar "$pct_val" 100 15)
                fi

                printf "  %-8s " "$swarm_name"
                printf "%-23b " "$colored_status"  # extra width for ANSI codes
                printf "%-26b " "$colored_phase"
                printf "%-10s " "$commits"
                printf "%b\n" "$progress_display"
            done

            echo ""

            # ── Alert: Errors ──
            if $has_errors; then
                echo -e "  ${C_BG_RED}${C_WHITE}${C_BOLD} ⚠  ALERT: $error_count swarm(s) in error state! ${C_RESET}"
                echo ""
                # Show details of errored swarms
                for status_file in "$state_dir"/swarms/*/status.json; do
                    [ -f "$status_file" ] || continue
                    local err_phase
                    err_phase=$(jq -r '.phase // ""' "$status_file" 2>/dev/null)
                    if [ "$err_phase" = "error" ] || [ "$err_phase" = "failed" ]; then
                        local err_name err_msg
                        err_name=$(basename "$(dirname "$status_file")")
                        err_msg=$(jq -r '.error // .message // "No details"' "$status_file" 2>/dev/null)
                        echo -e "  ${C_RED}✗ $err_name: $err_msg${C_RESET}"
                    fi
                done
                echo ""
            fi

            # ── Summary with progress bar ──
            echo -ne "  Summary: "
            if [ "$total_swarms" -gt 0 ]; then
                progress_bar "$done_count" "$total_swarms" 20
            else
                progress_bar 0 1 20
            fi
            echo -e "  ${C_GREEN}$done_count${C_RESET}/$total_swarms complete, ${C_RED}$error_count${C_RESET} errors"

            # ── Completion message ──
            if [ "$done_count" -eq "$total_swarms" ] && [ "$total_swarms" -gt 0 ]; then
                echo ""
                echo -e "  ${C_BG_GREEN}${C_WHITE}${C_BOLD} ✓  All $total_swarms swarms completed successfully! ${C_RESET}"
            fi

            # ── Metrics Integration ──
            render_metrics "$state_dir"

        else
            echo -e "  ${C_DIM}No state found for run $RUN_ID${C_RESET}"
        fi
    else
        # List all runs
        hr "Recent Runs"
        if [ -d "$HOME/.claude/multi-swarm/state" ]; then
            local run_found=false
            for run_dir in "$HOME/.claude/multi-swarm/state"/*/; do
                [ -d "$run_dir" ] || continue
                run_found=true
                local rid swarm_count
                rid=$(basename "$run_dir")
                swarm_count=$(find "$run_dir/swarms" -name "status.json" 2>/dev/null | wc -l | tr -d ' ')
                echo -e "  ${C_CYAN}▸${C_RESET} Run: ${C_BOLD}$rid${C_RESET} ($swarm_count swarms)"
            done
            if ! $run_found; then
                echo -e "  ${C_DIM}No runs found${C_RESET}"
            fi
        else
            echo -e "  ${C_DIM}No runs found${C_RESET}"
        fi
    fi

    echo ""
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
}

# ── Metrics Integration ────────────────────────────────────────────

render_metrics() {
    local state_dir="$1"
    local metrics_file="$state_dir/metrics.json"

    # Check multiple possible locations for metrics
    if [ ! -f "$metrics_file" ]; then
        metrics_file="$state_dir/metrics/summary.json"
    fi
    if [ ! -f "$metrics_file" ]; then
        # No metrics file found — try cost-tracker.sh as fallback
        local cost_tracker
        cost_tracker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cost-tracker.sh"
        if [ -f "$cost_tracker" ] && [ -n "${RUN_ID:-}" ]; then
            echo ""
            hr "Token Usage & Cost"
            source "$cost_tracker"
            get_cost_summary "$RUN_ID" 2>/dev/null || echo -e "  ${C_DIM}No cost data yet${C_RESET}"
            get_savings "$RUN_ID" 2>/dev/null || true
        fi
        return 0
    fi

    echo ""
    hr "Token Usage & Cost"

    local total_tokens total_cost model_info
    total_tokens=$(jq -r '.total_tokens // .tokens.total // "N/A"' "$metrics_file" 2>/dev/null)
    total_cost=$(jq -r '.total_cost // .cost.total // "N/A"' "$metrics_file" 2>/dev/null)
    model_info=$(jq -r '.model // .primary_model // "N/A"' "$metrics_file" 2>/dev/null)

    echo -e "  Tokens: ${C_BOLD}$total_tokens${C_RESET}"
    echo -e "  Cost:   ${C_BOLD}\$$total_cost${C_RESET}"
    if [ "$model_info" != "N/A" ]; then
        echo -e "  Model:  $model_info"
    fi

    # Per-swarm breakdown if available
    local has_swarm_metrics
    has_swarm_metrics=$(jq -r 'has("swarms") // has("per_swarm")' "$metrics_file" 2>/dev/null || echo "false")
    if [ "$has_swarm_metrics" = "true" ]; then
        echo ""
        printf "  ${C_DIM}%-10s %-12s %-10s${C_RESET}\n" "SWARM" "TOKENS" "COST"
        jq -r '(.swarms // .per_swarm) | to_entries[] | "  \(.key)|\(.value.tokens // "?")|\(.value.cost // "?")"' \
            "$metrics_file" 2>/dev/null | while IFS='|' read -r name tokens cost; do
            printf "  %-10s %-12s \$%-10s\n" "$name" "$tokens" "$cost"
        done
    fi
}

# ── Watch Mode ──────────────────────────────────────────────────────

run_watch_mode() {
    # Graceful exit on Ctrl+C
    trap 'printf "\n"; echo -e "${C_DIM}Monitor stopped.${C_RESET}"; exit 0' INT TERM

    # Hide cursor
    tput civis 2>/dev/null || true
    trap 'tput cnorm 2>/dev/null || true' EXIT

    while true; do
        # Clear screen and move cursor to top
        tput clear 2>/dev/null || printf "\033[2J\033[H"

        render_dashboard

        # Wait for interval, checking for keypress
        local waited=0
        while [ "$waited" -lt "$INTERVAL" ]; do
            # Read a single character with 1-second timeout
            if read -rsn1 -t 1 key 2>/dev/null; then
                case "$key" in
                    q|Q)
                        tput cnorm 2>/dev/null || true
                        echo -e "\n${C_DIM}Monitor stopped.${C_RESET}"
                        exit 0
                        ;;
                    r|R)
                        # Force immediate refresh
                        break
                        ;;
                esac
            fi
            waited=$((waited + 1))
        done
    done
}

# ── Main Entry Point ───────────────────────────────────────────────

if $CHECK_STATUS; then
    check_background_status
    exit 0
fi

if $STOP_BACKGROUND; then
    stop_background
    exit 0
fi

if $BACKGROUND_MODE; then
    start_background
    exit 0
fi

if $WATCH_MODE; then
    run_watch_mode
else
    # One-shot mode (original behavior)
    render_dashboard
fi
