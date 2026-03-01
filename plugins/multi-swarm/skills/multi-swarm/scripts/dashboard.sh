#!/usr/bin/env bash
set -euo pipefail

# Multi-Swarm Rich TUI Dashboard
# Usage: dashboard.sh <run-id> [--watch [interval]]
# Displays a full-screen TUI with live swarm status, progress bars,
# activity feed, token/cost tracking, commit timeline, file heatmap,
# and estimated time remaining.

###############################################################################
# Arguments & Config
###############################################################################
RUN_ID="${1:-}"
WATCH_MODE=false
WATCH_INTERVAL=5

show_usage() {
    echo "Usage: dashboard.sh <run-id> [--watch [interval]]"
    echo ""
    echo "Options:"
    echo "  --watch [N]   Continuously refresh every N seconds (default: 5)"
    echo ""
    echo "Available runs:"
    if [ -d "$HOME/.claude/multi-swarm/state" ]; then
        for d in "$HOME/.claude/multi-swarm/state"/*/; do
            [ -d "$d" ] || continue
            rid=$(basename "$d")
            cnt=$(find "$d/swarms" -name "status.json" 2>/dev/null | wc -l | tr -d ' ')
            echo "  $rid  ($cnt swarms)"
        done
    else
        echo "  (none)"
    fi
    exit 0
}

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "-h" ] || [ "$RUN_ID" = "--help" ]; then
    show_usage
    exit 0
fi

shift
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        --watch)
            WATCH_MODE=true
            if [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                WATCH_INTERVAL="$2"
                shift
            fi
            ;;
        *) ;;
    esac
    shift
done

STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [ ! -d "$STATE_DIR/swarms" ]; then
    echo "ERROR: No state found for run '$RUN_ID'"
    echo "Expected: $STATE_DIR/swarms/"
    echo ""
    echo "Available runs:"
    if [ -d "$HOME/.claude/multi-swarm/state" ]; then
        for d in "$HOME/.claude/multi-swarm/state"/*/; do
            [ -d "$d" ] || continue
            echo "  $(basename "$d")"
        done
    else
        echo "  (none)"
    fi
    exit 1
fi

###############################################################################
# Terminal helpers
###############################################################################
setup_term() {
    COLS=$(tput cols 2>/dev/null || echo 120)
    ROWS=$(tput lines 2>/dev/null || echo 40)
}

# Colors via tput
C_RESET=$(tput sgr0 2>/dev/null || printf '\033[0m')
C_BOLD=$(tput bold 2>/dev/null || printf '\033[1m')
C_DIM=$(tput dim 2>/dev/null || printf '\033[2m')
C_GREEN=$(tput setaf 2 2>/dev/null || printf '\033[32m')
C_YELLOW=$(tput setaf 3 2>/dev/null || printf '\033[33m')
C_BLUE=$(tput setaf 4 2>/dev/null || printf '\033[34m')
C_RED=$(tput setaf 1 2>/dev/null || printf '\033[31m')
C_CYAN=$(tput setaf 6 2>/dev/null || printf '\033[36m')
C_MAGENTA=$(tput setaf 5 2>/dev/null || printf '\033[35m')
C_WHITE=$(tput setaf 7 2>/dev/null || printf '\033[37m')
C_BG_BLACK=$(tput setab 0 2>/dev/null || printf '\033[40m')

# Cursor positioning
move_to()  { tput cup "$1" "$2" 2>/dev/null || printf '\033[%d;%dH' "$(($1+1))" "$(($2+1))"; }
hide_cursor() { tput civis 2>/dev/null || printf '\033[?25l'; }
show_cursor() { tput cnorm 2>/dev/null || printf '\033[?25h'; }
clear_screen() { tput clear 2>/dev/null || printf '\033[2J\033[H'; }

###############################################################################
# Drawing primitives
###############################################################################
# Box drawing chars
BOX_TL="╔" BOX_TR="╗" BOX_BL="╚" BOX_BR="╝"
BOX_H="═" BOX_V="║"
BOX_LT="╠" BOX_RT="╣" BOX_HT="╦" BOX_HB="╩"
LINE_H="─" LINE_V="│"
LINE_TL="┌" LINE_TR="┐" LINE_BL="└" LINE_BR="┘"
LINE_LT="├" LINE_RT="┤"

# Repeat a character N times
repeat_char() {
    local ch="$1" n="$2" result=""
    for ((i=0; i<n; i++)); do result+="$ch"; done
    printf '%s' "$result"
}

# Draw a horizontal line with optional title
hline() {
    local title="${1:-}" width="${2:-$COLS}" char="${3:-$LINE_H}"
    if [ -n "$title" ]; then
        local tlen=${#title}
        local pad_title=" $title "
        local left=2
        local right=$((width - left - tlen - 4))
        [ "$right" -lt 0 ] && right=0
        printf '%s%s%s%s%s%s%s' "$LINE_LT" "$(repeat_char "$char" $left)" \
            "$C_BOLD$C_CYAN" "$pad_title" "$C_RESET" \
            "$(repeat_char "$char" $right)" "$LINE_RT"
    else
        printf '%s%s%s' "$LINE_LT" "$(repeat_char "$char" $((width-2)))" "$LINE_RT"
    fi
}

# Truncate/pad a string to a fixed width
fixed_width() {
    local str="$1" w="$2"
    if [ ${#str} -gt "$w" ]; then
        printf '%s' "${str:0:$((w-1))}…"
    else
        printf "%-${w}s" "$str"
    fi
}

###############################################################################
# Phase color mapping
###############################################################################
phase_color() {
    case "$1" in
        done|completed|merged) echo "$C_GREEN" ;;
        working|implementing|coding) echo "$C_YELLOW" ;;
        analyzing|planning|launching) echo "$C_BLUE" ;;
        error|failed) echo "$C_RED" ;;
        testing|reviewing) echo "$C_CYAN" ;;
        pending|idle) echo "$C_DIM" ;;
        *) echo "$C_WHITE" ;;
    esac
}

# Phase to numeric progress (0-100)
phase_progress() {
    case "$1" in
        pending|launching) echo 5 ;;
        analyzing) echo 15 ;;
        planning) echo 25 ;;
        working|implementing|coding) echo 55 ;;
        testing|reviewing) echo 80 ;;
        done|completed|merged) echo 100 ;;
        error|failed) echo 0 ;;
        *) echo 10 ;;
    esac
}

###############################################################################
# Progress bar renderer
###############################################################################
progress_bar() {
    local pct="$1" width="${2:-20}" color="${3:-$C_GREEN}"
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    [ "$filled" -lt 0 ] && filled=0
    [ "$empty" -lt 0 ] && empty=0

    printf '%s' "$color"
    for ((i=0; i<filled; i++)); do printf '█'; done
    printf '%s' "$C_DIM"
    for ((i=0; i<empty; i++)); do printf '░'; done
    printf '%s %3d%%' "$C_RESET" "$pct"
}

###############################################################################
# Sparkline renderer (mini bar chart for token usage)
###############################################################################
sparkline() {
    local -a values=("$@")
    local max=1
    for v in "${values[@]}"; do
        [ "$v" -gt "$max" ] && max="$v"
    done
    local sparks=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
    for v in "${values[@]}"; do
        local idx=$((v * 7 / max))
        [ "$idx" -gt 7 ] && idx=7
        printf '%s%s' "$C_CYAN" "${sparks[$idx]}"
    done
    printf '%s' "$C_RESET"
}

###############################################################################
# Data collection
###############################################################################
collect_swarm_data() {
    SWARM_COUNT=0
    SWARMS_DONE=0
    SWARMS_ERROR=0
    TOTAL_TOKENS_IN=0
    TOTAL_TOKENS_OUT=0
    TOTAL_COST=0
    SWARM_DATA=()

    [ -d "$STATE_DIR/swarms" ] || return

    for status_file in "$STATE_DIR"/swarms/*/status.json; do
        [ -f "$status_file" ] || continue
        local sdir
        sdir=$(dirname "$status_file")
        local sname
        sname=$(basename "$sdir")

        local status phase commits progress team_size started_at updated_at summary error
        status=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null)
        phase=$(jq -r '.phase // "unknown"' "$status_file" 2>/dev/null)
        commits=$(jq -r '.commits // 0' "$status_file" 2>/dev/null)
        progress=$(jq -r '.progress // "0/0"' "$status_file" 2>/dev/null)
        team_size=$(jq -r '.teamSize // 0' "$status_file" 2>/dev/null)
        started_at=$(jq -r '.startedAt // ""' "$status_file" 2>/dev/null)
        updated_at=$(jq -r '.updatedAt // ""' "$status_file" 2>/dev/null)
        summary=$(jq -r '.summary // ""' "$status_file" 2>/dev/null)
        error=$(jq -r '.error // ""' "$status_file" 2>/dev/null)

        # Metrics (from metrics.sh output or embedded in status)
        local tokens_in=0 tokens_out=0 cost="0.00"
        local metrics_file="$sdir/metrics.json"
        if [ -f "$metrics_file" ]; then
            tokens_in=$(jq -r '.tokens.input // .tokensIn // .inputTokens // 0' "$metrics_file" 2>/dev/null)
            tokens_out=$(jq -r '.tokens.output // .tokensOut // .outputTokens // 0' "$metrics_file" 2>/dev/null)
            cost=$(jq -r '.cost.total // .cost // .estimatedCost // "0.00"' "$metrics_file" 2>/dev/null)
        fi

        TOTAL_TOKENS_IN=$((TOTAL_TOKENS_IN + tokens_in))
        TOTAL_TOKENS_OUT=$((TOTAL_TOKENS_OUT + tokens_out))
        TOTAL_COST=$(awk "BEGIN{printf \"%.2f\", $TOTAL_COST + $cost}")

        SWARM_COUNT=$((SWARM_COUNT + 1))
        case "$phase" in
            done|completed|merged) SWARMS_DONE=$((SWARMS_DONE + 1)) ;;
            error|failed) SWARMS_ERROR=$((SWARMS_ERROR + 1)) ;;
        esac

        # Store as delimited string for later use
        SWARM_DATA+=("${sname}|${status}|${phase}|${commits}|${progress}|${team_size}|${started_at}|${updated_at}|${summary}|${error}|${tokens_in}|${tokens_out}|${cost}")
    done
}

# Parse time to epoch seconds
to_epoch() {
    local ts="$1"
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null; then return; fi
    if date -d "$ts" "+%s" 2>/dev/null; then return; fi
    echo "0"
}

# Format duration
format_duration() {
    local secs="$1"
    if [ "$secs" -lt 60 ]; then
        printf '%ds' "$secs"
    elif [ "$secs" -lt 3600 ]; then
        printf '%dm %ds' $((secs/60)) $((secs%60))
    else
        printf '%dh %dm' $((secs/3600)) $(((secs%3600)/60))
    fi
}

# Format large numbers with K/M suffix
format_number() {
    local n="$1"
    if [ "$n" -ge 1000000 ]; then
        awk "BEGIN{printf \"%.1fM\", $n/1000000}"
    elif [ "$n" -ge 1000 ]; then
        awk "BEGIN{printf \"%.1fK\", $n/1000}"
    else
        echo "$n"
    fi
}

###############################################################################
# Widget: Header
###############################################################################
render_header() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local title="Multi-Swarm Dashboard"
    local run_label="Run: $RUN_ID"
    local time_label="$now"

    printf '%s%s%s' "$BOX_TL" "$(repeat_char "$BOX_H" $((COLS-2)))" "$BOX_TR"
    echo ""

    printf '%s ' "$BOX_V"
    printf '%s%s  %s%s' "$C_BOLD$C_MAGENTA" "◆" "$title" "$C_RESET"
    local left_len=$((4 + ${#title}))
    local right_str="$run_label  │  $time_label"
    local right_len=${#right_str}
    local gap=$((COLS - left_len - right_len - 3))
    [ "$gap" -lt 1 ] && gap=1
    printf '%*s' "$gap" ""
    printf '%s%s%s' "$C_DIM" "$right_str" "$C_RESET"
    printf ' %s' "$BOX_V"
    echo ""

    printf '%s%s%s' "$BOX_LT" "$(repeat_char "$BOX_H" $((COLS-2)))" "$BOX_RT"
    echo ""
}

###############################################################################
# Widget: Summary bar
###############################################################################
render_summary() {
    local elapsed_str="--"
    local eta_str="--"

    # Compute elapsed from earliest start
    local earliest_epoch=0 now_epoch
    now_epoch=$(date +%s)
    for entry in "${SWARM_DATA[@]}"; do
        IFS='|' read -r _ _ _ _ _ _ started _ _ _ _ _ _ <<< "$entry"
        if [ -n "$started" ] && [ "$started" != "null" ]; then
            local ep
            ep=$(to_epoch "$started")
            if [ "$ep" -gt 0 ]; then
                if [ "$earliest_epoch" -eq 0 ] || [ "$ep" -lt "$earliest_epoch" ]; then
                    earliest_epoch=$ep
                fi
            fi
        fi
    done

    local elapsed_secs=0
    if [ "$earliest_epoch" -gt 0 ]; then
        elapsed_secs=$((now_epoch - earliest_epoch))
        elapsed_str=$(format_duration $elapsed_secs)
    fi

    # ETA based on progress
    if [ "$SWARM_COUNT" -gt 0 ] && [ "$elapsed_secs" -gt 30 ] && [ "$SWARMS_DONE" -lt "$SWARM_COUNT" ]; then
        local total_pct=0
        for entry in "${SWARM_DATA[@]}"; do
            IFS='|' read -r _ _ phase _ _ _ _ _ _ _ _ _ _ <<< "$entry"
            total_pct=$((total_pct + $(phase_progress "$phase")))
        done
        local avg_pct=$((total_pct / SWARM_COUNT))
        if [ "$avg_pct" -gt 5 ]; then
            local est_total=$((elapsed_secs * 100 / avg_pct))
            local remaining=$((est_total - elapsed_secs))
            [ "$remaining" -lt 0 ] && remaining=0
            eta_str="~$(format_duration $remaining)"
        fi
    elif [ "$SWARMS_DONE" -eq "$SWARM_COUNT" ] && [ "$SWARM_COUNT" -gt 0 ]; then
        eta_str="complete"
    fi

    printf '%s ' "$LINE_V"
    printf '  %s%sSwarms:%s %d  ' "$C_BOLD" "$C_WHITE" "$C_RESET" "$SWARM_COUNT"
    printf '%s%s✓ Done:%s %d  ' "$C_GREEN" "$C_BOLD" "$C_RESET" "$SWARMS_DONE"
    if [ "$SWARMS_ERROR" -gt 0 ]; then
        printf '%s%s✗ Errors:%s %d  ' "$C_RED" "$C_BOLD" "$C_RESET" "$SWARMS_ERROR"
    fi
    printf '%s⏱ Elapsed:%s %s  ' "$C_DIM" "$C_RESET" "$elapsed_str"
    printf '%s⏳ ETA:%s %s' "$C_DIM" "$C_RESET" "$eta_str"
    local pad=$((COLS - 80))
    [ "$pad" -gt 0 ] && printf '%*s' "$pad" ""
    printf ' %s' "$LINE_V"
    echo ""
    hline "" "$COLS"
    echo ""
}

###############################################################################
# Widget: Swarm status table with progress bars
###############################################################################
render_swarm_table() {
    hline "Swarm Status" "$COLS"
    echo ""

    # Column headers
    printf '%s  ' "$LINE_V"
    printf '%s%-10s %-10s %-12s %-7s %-6s %-24s %s%s' \
        "$C_BOLD" "SWARM" "STATUS" "PHASE" "TASKS" "COMS" "PROGRESS" "SUMMARY" "$C_RESET"
    local hdr_len=75
    local hpad=$((COLS - hdr_len - 4))
    [ "$hpad" -gt 0 ] && printf '%*s' "$hpad" ""
    printf '  %s' "$LINE_V"
    echo ""

    printf '%s  %s  %s' "$LINE_V" "$(repeat_char "$LINE_H" $((COLS-4)))" "$LINE_V"
    echo ""

    for entry in "${SWARM_DATA[@]}"; do
        IFS='|' read -r sname sstatus sphase scommits sprogress steam_size sstarted supdated ssummary serror stok_in stok_out scost <<< "$entry"

        local color
        color=$(phase_color "$sphase")
        local pct
        pct=$(phase_progress "$sphase")

        # Parse task progress like "3/5"
        local tasks_str="$sprogress"

        printf '%s  ' "$LINE_V"
        printf '%-10s ' "$sname"
        printf '%s%-10s%s ' "$color" "$(fixed_width "$sstatus" 10)" "$C_RESET"
        printf '%s%-12s%s ' "$color" "$(fixed_width "$sphase" 12)" "$C_RESET"
        printf '%-7s ' "$tasks_str"
        printf '%-6s ' "$scommits"

        progress_bar "$pct" 16 "$color"

        # Summary (truncated)
        local sum_width=$((COLS - 82))
        [ "$sum_width" -lt 5 ] && sum_width=5
        if [ -n "$serror" ] && [ "$serror" != "null" ] && [ "$serror" != "" ]; then
            printf ' %s%s%s' "$C_RED" "$(fixed_width "$serror" $sum_width)" "$C_RESET"
        elif [ -n "$ssummary" ] && [ "$ssummary" != "null" ]; then
            printf ' %s' "$(fixed_width "$ssummary" $sum_width)"
        fi

        printf '  %s' "$LINE_V"
        echo ""
    done

    if [ "${#SWARM_DATA[@]}" -eq 0 ]; then
        printf '%s  %sNo swarm data found%s' "$LINE_V" "$C_DIM" "$C_RESET"
        local epad=$((COLS - 22))
        [ "$epad" -gt 0 ] && printf '%*s' "$epad" ""
        printf '  %s' "$LINE_V"
        echo ""
    fi
}

###############################################################################
# Widget: Token & Cost tracker
###############################################################################
render_tokens() {
    hline "Token Usage & Cost" "$COLS"
    echo ""

    printf '%s  ' "$LINE_V"
    printf '%s%-10s %12s %12s %10s%s' \
        "$C_BOLD" "SWARM" "TOKENS IN" "TOKENS OUT" "COST" "$C_RESET"
    local thpad=$((COLS - 50))
    [ "$thpad" -gt 0 ] && printf '%*s' "$thpad" ""
    printf '  %s' "$LINE_V"
    echo ""

    printf '%s  %s  %s' "$LINE_V" "$(repeat_char "$LINE_H" $((COLS-4)))" "$LINE_V"
    echo ""

    for entry in "${SWARM_DATA[@]}"; do
        IFS='|' read -r sname _ _ _ _ _ _ _ _ _ stok_in stok_out scost <<< "$entry"

        printf '%s  ' "$LINE_V"
        printf '%-10s ' "$sname"
        printf '%s%12s%s ' "$C_CYAN" "$(format_number "$stok_in")" "$C_RESET"
        printf '%s%12s%s ' "$C_YELLOW" "$(format_number "$stok_out")" "$C_RESET"
        printf '%s$%9s%s' "$C_GREEN" "$scost" "$C_RESET"
        local rpad=$((COLS - 50))
        [ "$rpad" -gt 0 ] && printf '%*s' "$rpad" ""
        printf '  %s' "$LINE_V"
        echo ""
    done

    # Total row
    printf '%s  %s  %s' "$LINE_V" "$(repeat_char "$LINE_H" $((COLS-4)))" "$LINE_V"
    echo ""
    printf '%s  ' "$LINE_V"
    printf '%s%s%-10s %12s %12s $%9s%s' \
        "$C_BOLD" "$C_WHITE" "TOTAL" \
        "$(format_number $TOTAL_TOKENS_IN)" \
        "$(format_number $TOTAL_TOKENS_OUT)" \
        "$TOTAL_COST" "$C_RESET"
    local tpad=$((COLS - 50))
    [ "$tpad" -gt 0 ] && printf '%*s' "$tpad" ""
    printf '  %s' "$LINE_V"
    echo ""
}

###############################################################################
# Widget: Commit Timeline
###############################################################################
render_commits() {
    hline "Commit Timeline" "$COLS"
    echo ""

    local has_commits=false
    for entry in "${SWARM_DATA[@]}"; do
        IFS='|' read -r sname _ sphase _ _ _ _ _ _ _ _ _ _ <<< "$entry"

        # Extract swarm number from sname (e.g., "swarm-1" -> "1")
        local snum="${sname#swarm-}"
        local branch_pattern="swarm/${RUN_ID}/${snum}-"

        # Find matching branch
        local branch=""
        branch=$(git branch --list "swarm/${RUN_ID}/${snum}-*" 2>/dev/null | head -1 | tr -d ' *' || true)
        [ -z "$branch" ] && continue

        local color
        color=$(phase_color "$sphase")

        # Get last 3 commits on this branch
        local commits
        commits=$(git log "$branch" --format="%h %s" -n 3 2>/dev/null || true)
        [ -z "$commits" ] && continue

        has_commits=true
        printf '%s  %s%s%s (%s)' "$LINE_V" "$color$C_BOLD" "$sname" "$C_RESET" "$branch"
        local bpad=$((COLS - ${#sname} - ${#branch} - 8))
        [ "$bpad" -gt 0 ] && printf '%*s' "$bpad" ""
        printf '  %s' "$LINE_V"
        echo ""

        while IFS= read -r cline; do
            [ -z "$cline" ] && continue
            local chash="${cline%% *}"
            local cmsg="${cline#* }"
            local msg_width=$((COLS - 20))
            [ "$msg_width" -lt 10 ] && msg_width=10
            printf '%s    %s%s%s %s' "$LINE_V" "$C_DIM" "$chash" "$C_RESET" "$(fixed_width "$cmsg" $msg_width)"
            printf '  %s' "$LINE_V"
            echo ""
        done <<< "$commits"
    done

    if [ "$has_commits" = false ]; then
        printf '%s  %sNo commits yet%s' "$LINE_V" "$C_DIM" "$C_RESET"
        local epad=$((COLS - 18))
        [ "$epad" -gt 0 ] && printf '%*s' "$epad" ""
        printf '  %s' "$LINE_V"
        echo ""
    fi
}

###############################################################################
# Widget: File Change Heatmap
###############################################################################
render_heatmap() {
    hline "File Change Heatmap" "$COLS"
    echo ""

    # Collect file stats into a temp file (bash 3.2 compatible - no assoc arrays)
    local tmpfile
    tmpfile=$(mktemp /tmp/dashboard-heatmap.XXXXXX)
    trap "rm -f '$tmpfile'" RETURN 2>/dev/null || true

    for entry in "${SWARM_DATA[@]}"; do
        IFS='|' read -r sname _ _ _ _ _ _ _ _ _ _ _ _ <<< "$entry"
        local snum="${sname#swarm-}"

        local branch=""
        branch=$(git branch --list "swarm/${RUN_ID}/${snum}-*" 2>/dev/null | head -1 | tr -d ' *' || true)
        [ -z "$branch" ] && continue

        local base_branch="main"
        local merge_base
        merge_base=$(git merge-base "$base_branch" "$branch" 2>/dev/null || true)
        [ -z "$merge_base" ] && continue

        git diff --numstat "$merge_base".."$branch" 2>/dev/null | awk '{
            adds = $1; dels = $2; fname = $3
            if (adds != "-" && dels != "-" && fname != "")
                print (adds + dels) "\t" fname
        }' >> "$tmpfile" || true
    done

    # Aggregate by filename, sort descending
    local sorted
    sorted=$(awk -F'\t' '{counts[$2]+=$1} END {for(f in counts) print counts[f] "\t" f}' "$tmpfile" 2>/dev/null | sort -t$'\t' -k1 -rn)
    rm -f "$tmpfile"

    if [ -z "$sorted" ]; then
        printf '%s  %sNo file changes detected%s' "$LINE_V" "$C_DIM" "$C_RESET"
        local epad=$((COLS - 28))
        [ "$epad" -gt 0 ] && printf '%*s' "$epad" ""
        printf '  %s' "$LINE_V"
        echo ""
        return
    fi

    local max_count
    max_count=$(echo "$sorted" | head -1 | cut -f1)
    [ -z "$max_count" ] || [ "$max_count" -eq 0 ] && max_count=1

    local max_show=8
    local total_files
    total_files=$(echo "$sorted" | wc -l | tr -d ' ')

    echo "$sorted" | head -n "$max_show" | while IFS=$'\t' read -r cnt fname; do
        [ -z "$cnt" ] || [ -z "$fname" ] && continue

        # Heat level 0-3
        local heat=$((cnt * 3 / max_count))
        [ "$heat" -gt 3 ] && heat=3

        local heat_color="$C_GREEN"
        local heat_char="░"
        if [ "$heat" -ge 3 ]; then
            heat_color="$C_RED$C_BOLD"; heat_char="█"
        elif [ "$heat" -ge 2 ]; then
            heat_color="$C_RED"; heat_char="▓"
        elif [ "$heat" -ge 1 ]; then
            heat_color="$C_YELLOW"; heat_char="▒"
        fi

        local bar_width=10
        local bar_filled=$((cnt * bar_width / max_count))
        [ "$bar_filled" -lt 1 ] && bar_filled=1
        local bar=""
        local i=0
        while [ "$i" -lt "$bar_filled" ]; do
            bar="${bar}${heat_char}"
            i=$((i + 1))
        done

        local fname_width=$((COLS - bar_width - 18))
        [ "$fname_width" -lt 20 ] && fname_width=20

        printf '%s  %s%3d%s %s%-*s%s %s' \
            "$LINE_V" "$C_BOLD" "$cnt" "$C_RESET" \
            "$heat_color" "$bar_width" "$bar" "$C_RESET" \
            "$(fixed_width "$fname" $fname_width)"
        printf '  %s' "$LINE_V"
        echo ""
    done

    local remaining=$((total_files - max_show))
    if [ "$remaining" -gt 0 ]; then
        printf '%s  %s... and %d more files%s' "$LINE_V" "$C_DIM" "$remaining" "$C_RESET"
        local rpad=$((COLS - 24 - ${#remaining}))
        [ "$rpad" -gt 0 ] && printf '%*s' "$rpad" ""
        printf '  %s' "$LINE_V"
        echo ""
    fi
}

###############################################################################
# Widget: Agent Activity Feed
###############################################################################
render_activity() {
    hline "Agent Activity" "$COLS"
    echo ""

    local has_activity=false

    # Read team configs and task lists
    if [ -d "$HOME/.claude/teams" ]; then
        for team_config in "$HOME/.claude/teams"/*/config.json; do
            [ -f "$team_config" ] || continue
            local team_name
            team_name=$(jq -r '.name // "unknown"' "$team_config" 2>/dev/null)

            # Only show teams related to this run
            if [[ "$team_name" != *"$RUN_ID"* ]] && [[ "$team_name" != *"swarm"* ]]; then
                continue
            fi

            local members
            members=$(jq -r '.members[]? .name // empty' "$team_config" 2>/dev/null || true)
            [ -z "$members" ] && continue

            has_activity=true
            printf '%s  %s%s%s%s ' "$LINE_V" "$C_BOLD" "$C_MAGENTA" "$team_name" "$C_RESET"
            local mcount
            mcount=$(jq -r '.members | length' "$team_config" 2>/dev/null || echo "0")
            printf '%s(%s members)%s' "$C_DIM" "$mcount" "$C_RESET"
            local tpad=$((COLS - ${#team_name} - 16 - ${#mcount}))
            [ "$tpad" -gt 0 ] && printf '%*s' "$tpad" ""
            printf '  %s' "$LINE_V"
            echo ""

            # Show tasks for this team
            local task_dir="$HOME/.claude/tasks/$team_name"
            if [ -d "$task_dir" ]; then
                for task_file in "$task_dir"/*.json; do
                    [ -f "$task_file" ] || continue
                    local tsubject tstatus towner
                    tsubject=$(jq -r '.subject // ""' "$task_file" 2>/dev/null)
                    tstatus=$(jq -r '.status // "unknown"' "$task_file" 2>/dev/null)
                    towner=$(jq -r '.owner // ""' "$task_file" 2>/dev/null)

                    local ticon tcolor
                    case "$tstatus" in
                        completed) ticon="✓"; tcolor="$C_GREEN" ;;
                        in_progress) ticon="●"; tcolor="$C_YELLOW" ;;
                        pending) ticon="○"; tcolor="$C_DIM" ;;
                        *) ticon="?"; tcolor="$C_WHITE" ;;
                    esac

                    local sub_width=$((COLS - 30))
                    [ "$sub_width" -lt 10 ] && sub_width=10

                    printf '%s    %s%s%s ' "$LINE_V" "$tcolor" "$ticon" "$C_RESET"
                    printf '%s' "$(fixed_width "$tsubject" $sub_width)"
                    if [ -n "$towner" ] && [ "$towner" != "null" ]; then
                        printf ' %s[%s]%s' "$C_DIM" "$towner" "$C_RESET"
                    fi
                    printf '  %s' "$LINE_V"
                    echo ""
                done
            fi
        done
    fi

    if [ "$has_activity" = false ]; then
        printf '%s  %sNo active agent teams%s' "$LINE_V" "$C_DIM" "$C_RESET"
        local epad=$((COLS - 25))
        [ "$epad" -gt 0 ] && printf '%*s' "$epad" ""
        printf '  %s' "$LINE_V"
        echo ""
    fi
}

###############################################################################
# Widget: Footer
###############################################################################
render_footer() {
    printf '%s%s%s' "$BOX_LT" "$(repeat_char "$BOX_H" $((COLS-2)))" "$BOX_RT"
    echo ""

    printf '%s ' "$BOX_V"
    if [ "$WATCH_MODE" = true ]; then
        printf ' %s%sq%s=quit  %s%sr%s=refresh  %s%s↻ auto-refresh: %ds%s' \
            "$C_BOLD" "$C_CYAN" "$C_RESET" \
            "$C_BOLD" "$C_CYAN" "$C_RESET" \
            "$C_DIM" "$C_GREEN" "$WATCH_INTERVAL" "$C_RESET"
    else
        printf ' %sRun with --watch for live updates%s' "$C_DIM" "$C_RESET"
    fi
    local fpad=$((COLS - 55))
    [ "$fpad" -gt 0 ] && printf '%*s' "$fpad" ""
    printf ' %s' "$BOX_V"
    echo ""

    printf '%s%s%s' "$BOX_BL" "$(repeat_char "$BOX_H" $((COLS-2)))" "$BOX_BR"
    echo ""
}

###############################################################################
# Main render pass
###############################################################################
render() {
    setup_term
    collect_swarm_data

    if [ "$WATCH_MODE" = true ]; then
        clear_screen
        hide_cursor
    fi

    render_header
    render_summary
    render_swarm_table
    render_tokens
    render_commits
    render_heatmap
    render_activity
    render_footer
}

###############################################################################
# Cleanup on exit
###############################################################################
cleanup() {
    show_cursor
    tput rmcup 2>/dev/null || true
    printf '\033[?1049l' 2>/dev/null || true
}

###############################################################################
# Entry point
###############################################################################
if [ "$WATCH_MODE" = true ]; then
    trap cleanup EXIT INT TERM

    # Enter alternate screen buffer
    tput smcup 2>/dev/null || printf '\033[?1049h'

    while true; do
        render

        # Non-blocking key read for quit/refresh
        if read -rsn1 -t "$WATCH_INTERVAL" key 2>/dev/null; then
            case "$key" in
                q|Q) break ;;
                r|R) continue ;;
            esac
        fi
    done

    cleanup
else
    render
fi
