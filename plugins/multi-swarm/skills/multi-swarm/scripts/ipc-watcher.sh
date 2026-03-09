#!/usr/bin/env bash
set -euo pipefail

# IPC Watcher — Background daemon for monitoring inter-swarm messages
# Usage: ipc-watcher.sh start|stop|status <run-id> <swarm-id> [--interval <seconds>]
#
# Environment variables:
#   HOME  — Base directory for state storage ($HOME/.claude/multi-swarm/state/)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:?Usage: ipc-watcher.sh start|stop|status <run-id> <swarm-id>}"
RUN_ID="${2:?Run ID required}"
SWARM_ID="${3:?Swarm ID required}"

STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
SWARM_DIR="$STATE_DIR/swarms/swarm-${SWARM_ID}"
PID_FILE="$SWARM_DIR/ipc-watcher.pid"
LOG_FILE="$SWARM_DIR/ipc-watcher.log"
INBOX_FILE="$SWARM_DIR/ipc-inbox.md"
MAX_INBOX_MESSAGES=50

# Parse optional flags
INTERVAL=10
shift 3 || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="${2:?Interval value required}"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"
}

# Format a single JSON message into a markdown section
format_message() {
    local msg="$1"
    local msg_type msg_sender msg_ts msg_body
    msg_type=$(echo "$msg" | jq -r '.type // "INFO"')
    msg_sender=$(echo "$msg" | jq -r '.sender // "unknown"')
    msg_ts=$(echo "$msg" | jq -r '.timestamp // "unknown"')
    msg_body=$(echo "$msg" | jq -r '.message // ""')
    echo "## ${msg_type} from swarm-${msg_sender} (${msg_ts})"
    echo "$msg_body"
    echo ""
}

# Sort messages: BLOCKERs first, then by timestamp
sort_messages() {
    local messages="$1"
    local blockers others
    blockers=$(echo "$messages" | jq -c '[.[] | select(.type == "BLOCKER")] | sort_by(.timestamp)' 2>/dev/null || echo "[]")
    others=$(echo "$messages" | jq -c '[.[] | select(.type != "BLOCKER")] | sort_by(.timestamp)' 2>/dev/null || echo "[]")
    # Merge: blockers first
    echo "$blockers $others" | jq -c -s 'add'
}

# Write messages to the inbox file, keeping only the last N
write_inbox() {
    local new_entries="$1"
    local keep=0

    # Calculate how many old entries to preserve
    if [ -f "$INBOX_FILE" ]; then
        local new_count
        new_count=$(echo "$new_entries" | jq 'length' 2>/dev/null || echo "0")
        keep=$(( MAX_INBOX_MESSAGES - new_count ))
        if [ "$keep" -lt 0 ]; then
            keep=0
        fi
    fi

    # Build the new inbox file
    {
        echo "# IPC Messages"
        echo ""

        # Write new messages (formatted from JSON, sorted with BLOCKERs first)
        local sorted
        sorted=$(sort_messages "$new_entries")
        local count
        count=$(echo "$sorted" | jq 'length' 2>/dev/null || echo "0")
        for (( i=0; i<count; i++ )); do
            local msg
            msg=$(echo "$sorted" | jq -c ".[$i]")
            format_message "$msg"
        done

        # Preserve existing messages (skip header, keep up to limit)
        if [ -f "$INBOX_FILE" ] && [ "$keep" -gt 0 ]; then
            local section_count=0
            local in_section=false
            while IFS= read -r line; do
                if [[ "$line" =~ ^##\  ]]; then
                    section_count=$((section_count + 1))
                    if [ "$section_count" -gt "$keep" ]; then
                        break
                    fi
                    in_section=true
                fi
                if [ "$in_section" = true ]; then
                    echo "$line"
                fi
            done < <(tail -n +3 "$INBOX_FILE")
        fi

        echo "---"
        echo "Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${INBOX_FILE}.tmp"
    mv "${INBOX_FILE}.tmp" "$INBOX_FILE"
}

SHUTDOWN_REQUESTED=false

# The main polling loop
poll_loop() {
    log "Watcher started (interval=${INTERVAL}s, swarm=${SWARM_ID})"

    # Set flag on signals instead of exiting directly
    trap 'SHUTDOWN_REQUESTED=true; log "Received shutdown signal"' SIGTERM SIGINT

    while [ "$SHUTDOWN_REQUESTED" = false ]; do
        log "Polling for new messages..."

        # Fetch unread messages for this swarm (--for also matches target="all")
        local all_messages
        all_messages=$("${SCRIPT_DIR}/ipc.sh" list "$RUN_ID" --for "$SWARM_ID" --unread 2>/dev/null || echo "[]")

        local msg_count
        msg_count=$(echo "$all_messages" | jq 'length' 2>/dev/null || echo "0")

        if [ "$msg_count" -gt 0 ]; then
            log "Found $msg_count new message(s)"

            # Write to inbox
            write_inbox "$all_messages"

            # Ack each message
            for (( i=0; i<msg_count; i++ )); do
                local msg_id
                msg_id=$(echo "$all_messages" | jq -r ".[$i].id" 2>/dev/null || echo "")
                if [ -n "$msg_id" ] && [ "$msg_id" != "null" ]; then
                    "${SCRIPT_DIR}/ipc.sh" ack "$RUN_ID" "$SWARM_ID" "$msg_id" 2>/dev/null || log "Failed to ack message $msg_id"
                fi
            done

            log "Wrote $msg_count message(s) to inbox and acked"
        else
            log "No new messages"
        fi

        # Record last check time
        date -u +%Y-%m-%dT%H:%M:%SZ > "$SWARM_DIR/ipc-watcher-lastcheck"

        # Check flag before sleeping
        if [ "$SHUTDOWN_REQUESTED" = true ]; then
            break
        fi

        sleep "$INTERVAL" &
        wait $! 2>/dev/null || true  # Allow signal to interrupt sleep
    done

    log "Watcher shutting down gracefully"
    rm -f "$PID_FILE"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_start() {
    mkdir -p "$SWARM_DIR"

    # Use mkdir-based locking for atomic PID file handling (portable, works on macOS)
    LOCK_DIR="${PID_FILE}.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Another watcher instance is starting" >&2
        exit 1
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

    # Check if already running (now under lock)
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "IPC watcher already running (PID $OLD_PID)"
            exit 1
        fi
        # Stale PID file
        rm -f "$PID_FILE"
    fi

    # Launch polling loop in background
    poll_loop &
    WATCHER_PID=$!
    echo "$WATCHER_PID" > "$PID_FILE"

    # Lock released via EXIT trap (rmdir)
    echo "IPC watcher started for swarm-${SWARM_ID} (PID $WATCHER_PID, interval ${INTERVAL}s)"
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "No PID file found — watcher not running"
        exit 0
    fi

    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        # Wait briefly for graceful shutdown
        for _ in $(seq 1 5); do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Force kill if still alive
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID" 2>/dev/null || true
        fi
        echo "IPC watcher stopped (PID $PID)"
    else
        echo "IPC watcher not running (stale PID $PID)"
    fi
    rm -f "$PID_FILE"
}

cmd_status() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "IPC watcher: RUNNING (PID $pid)"
        else
            echo "IPC watcher: STOPPED (stale PID $pid)"
        fi
    else
        echo "IPC watcher: NOT RUNNING"
    fi

    # Last check time
    if [ -f "$SWARM_DIR/ipc-watcher-lastcheck" ]; then
        echo "Last check: $(cat "$SWARM_DIR/ipc-watcher-lastcheck")"
    else
        echo "Last check: never"
    fi

    # Unread count (--for matches both direct and "all" target)
    local unread
    unread=$("${SCRIPT_DIR}/ipc.sh" list "$RUN_ID" --for "$SWARM_ID" --unread 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    echo "Unread messages: $unread"

    # Inbox message count
    if [ -f "$INBOX_FILE" ]; then
        local inbox_count
        inbox_count=$(grep -c '^## ' "$INBOX_FILE" 2>/dev/null || echo "0")
        echo "Inbox messages: $inbox_count"
    else
        echo "Inbox messages: 0"
    fi
}

case "$COMMAND" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *)
        echo "Usage: ipc-watcher.sh start|stop|status <run-id> <swarm-id> [--interval <seconds>]"
        exit 1
        ;;
esac
