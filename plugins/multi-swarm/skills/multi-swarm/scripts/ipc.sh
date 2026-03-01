#!/usr/bin/env bash
set -euo pipefail

# Inter-Swarm IPC Message Bus
# Usage: ipc.sh <command> <run-id> [args...]
#
# Commands:
#   send   <run-id> <sender-id> <type> <target|"all"> <message>
#   list   <run-id> [--for <swarm-id>] [--type <type>] [--since <timestamp>] [--unread]
#   read   <run-id> <message-id>
#   ack    <run-id> <swarm-id> <message-id>
#   status <run-id>

usage() {
    cat <<EOF
Usage: ipc.sh <command> [args...]

Commands:
  send   <run-id> <sender-id> <type> <target|"all"> <message>
         Types: DISCOVERY, BLOCKER, BROADCAST, REQUEST

  list   <run-id> [--for <swarm-id>] [--type <type>] [--since <timestamp>] [--unread]
         List messages with optional filters

  read   <run-id> <message-id>
         Read a single message by ID

  ack    <run-id> <swarm-id> <message-id>
         Acknowledge a message for a swarm

  status <run-id>
         Show IPC message summary
EOF
    exit 1
}

VALID_TYPES="DISCOVERY BLOCKER BROADCAST REQUEST"

validate_type() {
    local type="$1"
    if ! echo "$VALID_TYPES" | grep -qw "$type"; then
        echo "ERROR: Invalid message type '$type'. Must be one of: $VALID_TYPES" >&2
        exit 1
    fi
}

ipc_dir() {
    local run_id="$1"
    echo "$HOME/.claude/multi-swarm/state/${run_id}/ipc"
}

ensure_dirs() {
    local run_id="$1"
    local base
    base="$(ipc_dir "$run_id")"
    mkdir -p "$base/messages"
    mkdir -p "$base/acks"
}

generate_id() {
    # Short unique ID from /dev/urandom
    LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8 || true
}

# ── send ──────────────────────────────────────────────────────────────────────

cmd_send() {
    local run_id="${1:?Usage: ipc.sh send <run-id> <sender-id> <type> <target|\"all\"> <message>}"
    local sender="${2:?Sender ID required}"
    local type="${3:?Message type required}"
    local target="${4:?Target required (swarm ID or \"all\")}"
    local message="${5:?Message content required}"

    validate_type "$type"
    ensure_dirs "$run_id"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local msg_id
    msg_id="$(generate_id)"
    local filename="${timestamp//:/}-${sender}-${type}-${msg_id}.json"
    local base
    base="$(ipc_dir "$run_id")"

    local msg_json
    msg_json=$(jq -n \
        --arg id "$msg_id" \
        --arg type "$type" \
        --arg sender "$sender" \
        --arg target "$target" \
        --arg timestamp "$timestamp" \
        --arg message "$message" \
        '{
            id: $id,
            type: $type,
            sender: $sender,
            target: $target,
            timestamp: $timestamp,
            message: $message,
            acked_by: []
        }')

    echo "$msg_json" > "$base/messages/$filename"
    echo "$msg_id"
}

# ── list ──────────────────────────────────────────────────────────────────────

cmd_list() {
    local run_id="${1:?Usage: ipc.sh list <run-id> [--for <swarm-id>] [--type <type>] [--since <timestamp>] [--unread]}"
    shift

    ensure_dirs "$run_id"

    local filter_for="" filter_type="" filter_since="" filter_unread=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --for)    filter_for="${2:?--for requires a swarm-id}"; shift 2 ;;
            --type)   filter_type="${2:?--type requires a type}"; shift 2 ;;
            --since)  filter_since="${2:?--since requires a timestamp}"; shift 2 ;;
            --unread) filter_unread=true; shift ;;
            *)        echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
        esac
    done

    if [ -n "$filter_type" ]; then
        validate_type "$filter_type"
    fi

    local base
    base="$(ipc_dir "$run_id")"
    local messages_dir="$base/messages"

    # Collect and filter messages
    local results="[]"
    for msg_file in "$messages_dir"/*.json; do
        [ -f "$msg_file" ] || continue

        local msg
        msg="$(cat "$msg_file")"

        # Filter by target (--for): show messages targeted at this swarm or "all"
        if [ -n "$filter_for" ]; then
            local msg_target
            msg_target="$(echo "$msg" | jq -r '.target')"
            if [ "$msg_target" != "all" ] && [ "$msg_target" != "$filter_for" ]; then
                continue
            fi
        fi

        # Filter by type
        if [ -n "$filter_type" ]; then
            local msg_type
            msg_type="$(echo "$msg" | jq -r '.type')"
            if [ "$msg_type" != "$filter_type" ]; then
                continue
            fi
        fi

        # Filter by since (ISO-8601 string comparison)
        if [ -n "$filter_since" ]; then
            local msg_ts
            msg_ts="$(echo "$msg" | jq -r '.timestamp')"
            if [[ "$msg_ts" < "$filter_since" ]]; then
                continue
            fi
        fi

        # Filter unread (not acked by --for swarm)
        if [ "$filter_unread" = true ]; then
            if [ -z "$filter_for" ]; then
                echo "ERROR: --unread requires --for <swarm-id>" >&2
                exit 1
            fi
            local msg_id
            msg_id="$(echo "$msg" | jq -r '.id')"
            if [ -f "$base/acks/${filter_for}/${msg_id}" ]; then
                continue
            fi
        fi

        results="$(echo "$results" | jq --argjson m "$msg" '. + [$m]')"
    done

    # Sort by timestamp and output
    echo "$results" | jq 'sort_by(.timestamp)'
}

# ── read ──────────────────────────────────────────────────────────────────────

cmd_read() {
    local run_id="${1:?Usage: ipc.sh read <run-id> <message-id>}"
    local msg_id="${2:?Message ID required}"

    local base
    base="$(ipc_dir "$run_id")"
    local messages_dir="$base/messages"

    for msg_file in "$messages_dir"/*-"${msg_id}".json; do
        if [ -f "$msg_file" ]; then
            # Enrich with ack info from ack directories
            local msg
            msg="$(cat "$msg_file")"
            local acked_by="[]"

            if [ -d "$base/acks" ]; then
                for ack_dir in "$base/acks"/*/; do
                    [ -d "$ack_dir" ] || continue
                    local swarm_id
                    swarm_id="$(basename "$ack_dir")"
                    if [ -f "$ack_dir/$msg_id" ]; then
                        acked_by="$(echo "$acked_by" | jq --arg s "$swarm_id" '. + [$s]')"
                    fi
                done
            fi

            echo "$msg" | jq --argjson acked "$acked_by" '.acked_by = $acked'
            return 0
        fi
    done

    echo "ERROR: Message '$msg_id' not found" >&2
    exit 1
}

# ── ack ───────────────────────────────────────────────────────────────────────

cmd_ack() {
    local run_id="${1:?Usage: ipc.sh ack <run-id> <swarm-id> <message-id>}"
    local swarm_id="${2:?Swarm ID required}"
    local msg_id="${3:?Message ID required}"

    local base
    base="$(ipc_dir "$run_id")"

    # Verify message exists
    local found=false
    for msg_file in "$base/messages"/*-"${msg_id}".json; do
        if [ -f "$msg_file" ]; then
            found=true
            break
        fi
    done

    if [ "$found" = false ]; then
        echo "ERROR: Message '$msg_id' not found" >&2
        exit 1
    fi

    # Create ack
    mkdir -p "$base/acks/${swarm_id}"
    touch "$base/acks/${swarm_id}/${msg_id}"
    echo "ACK: $swarm_id acknowledged $msg_id"
}

# ── status ────────────────────────────────────────────────────────────────────

cmd_status() {
    local run_id="${1:?Usage: ipc.sh status <run-id>}"

    local base
    base="$(ipc_dir "$run_id")"

    if [ ! -d "$base/messages" ]; then
        echo "No IPC messages for run $run_id"
        return 0
    fi

    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              IPC Message Bus Status                  ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo ""
    echo "  Run ID: $run_id"
    echo ""

    # Count by type
    echo "── Messages by Type ─────────────────────────────────"
    local total=0
    for type in DISCOVERY BLOCKER BROADCAST REQUEST; do
        local count=0
        for msg_file in "$base/messages"/*.json; do
            [ -f "$msg_file" ] || continue
            local msg_type
            msg_type="$(jq -r '.type' "$msg_file" 2>/dev/null)"
            if [ "$msg_type" = "$type" ]; then
                count=$((count + 1))
            fi
        done
        total=$((total + count))
        printf "  %-12s %d\n" "$type" "$count"
    done
    echo "  ────────────────"
    printf "  %-12s %d\n" "TOTAL" "$total"
    echo ""

    # Unacked messages per swarm
    echo "── Unacked Messages per Swarm ───────────────────────"
    if [ -d "$base/acks" ]; then
        for ack_dir in "$base/acks"/*/; do
            [ -d "$ack_dir" ] || continue
            local swarm_id
            swarm_id="$(basename "$ack_dir")"
            local acked=0
            for ack_file in "$ack_dir"/*; do
                [ -f "$ack_file" ] || continue
                acked=$((acked + 1))
            done
            local unacked=$((total - acked))
            printf "  %-12s %d unacked (of %d total)\n" "$swarm_id" "$unacked" "$total"
        done
    else
        echo "  No acks recorded yet"
    fi

    echo ""
    echo "╚══════════════════════════════════════════════════════╝"
}

# ── main ──────────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    send)   cmd_send "$@" ;;
    list)   cmd_list "$@" ;;
    read)   cmd_read "$@" ;;
    ack)    cmd_ack "$@" ;;
    status) cmd_status "$@" ;;
    -h|--help|help) usage ;;
    *)      usage ;;
esac
