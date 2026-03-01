#!/usr/bin/env bash
set -euo pipefail

# Multi-Swarm Monitor
# Usage: monitor.sh [run-id]
# Shows status dashboard for active swarms

RUN_ID="${1:-}"
GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"
GATEWAY_PORT=$(jq -r '.gateway.port // 4000' "$GLOBAL_CONFIG" 2>/dev/null || echo "4000")
MASTER_KEY=$(jq -r '.gateway.masterKey // "sk-swarm-master"' "$GLOBAL_CONFIG" 2>/dev/null || echo "sk-swarm-master")

echo "╔══════════════════════════════════════════════════════╗"
echo "║           Multi-Swarm Status Dashboard              ║"
echo "╠══════════════════════════════════════════════════════╣"
echo ""

# Gateway Status
echo "── Gateway ──────────────────────────────────────────"
if curl -sf -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
    echo "  Status: HEALTHY (port $GATEWAY_PORT)"
    # Try to get model info
    MODEL_COUNT=$(curl -sf -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${GATEWAY_PORT}/health" 2>/dev/null | jq '[.healthy_endpoints, .unhealthy_endpoints] | map(length) | {healthy: .[0], unhealthy: .[1]}' 2>/dev/null || echo "{}")
    echo "  Models: $MODEL_COUNT"
else
    echo "  Status: DOWN"
fi
echo ""

# Active Worktrees
echo "── Worktrees ────────────────────────────────────────"
if git worktree list 2>/dev/null | grep -v "^$"; then
    git worktree list 2>/dev/null | while read -r line; do
        echo "  $line"
    done
else
    echo "  No worktrees active"
fi
echo ""

# tmux Sessions
echo "── tmux Sessions ────────────────────────────────────"
if command -v tmux &>/dev/null; then
    SESSIONS=$(tmux list-sessions 2>/dev/null | grep "swarm" || echo "")
    if [ -n "$SESSIONS" ]; then
        echo "$SESSIONS" | while read -r line; do
            echo "  $line"
        done
    else
        echo "  No swarm sessions active"
    fi
else
    echo "  tmux not available"
fi
echo ""

# Agent Teams
echo "── Agent Teams ──────────────────────────────────────"
if [ -d "$HOME/.claude/teams" ]; then
    for team_config in "$HOME/.claude/teams"/*/config.json; do
        [ -f "$team_config" ] || continue
        TEAM_NAME=$(jq -r '.name // "unknown"' "$team_config" 2>/dev/null)
        MEMBER_COUNT=$(jq -r '.members | length // 0' "$team_config" 2>/dev/null)
        echo "  Team: $TEAM_NAME ($MEMBER_COUNT members)"
    done
else
    echo "  No active teams"
fi
echo ""

# Swarm Status (if run-id provided)
if [ -n "$RUN_ID" ]; then
    STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
    if [ -d "$STATE_DIR/swarms" ]; then
        echo "── Swarm Progress (Run: ${RUN_ID}) ─────────────────"
        echo ""
        printf "  %-8s %-12s %-15s %-10s %s\n" "SWARM" "STATUS" "PHASE" "COMMITS" "PROGRESS"
        printf "  %-8s %-12s %-15s %-10s %s\n" "-----" "------" "-----" "-------" "--------"

        for status_file in "$STATE_DIR"/swarms/*/status.json; do
            [ -f "$status_file" ] || continue
            SWARM_DIR=$(dirname "$status_file")
            SWARM_NAME=$(basename "$SWARM_DIR")

            STATUS=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null)
            PHASE=$(jq -r '.phase // "unknown"' "$status_file" 2>/dev/null)
            COMMITS=$(jq -r '.commits // 0' "$status_file" 2>/dev/null)
            PROGRESS=$(jq -r '.progress // "N/A"' "$status_file" 2>/dev/null)

            printf "  %-8s %-12s %-15s %-10s %s\n" "$SWARM_NAME" "$STATUS" "$PHASE" "$COMMITS" "$PROGRESS"
        done

        echo ""

        # Summary
        TOTAL=$(find "$STATE_DIR/swarms" -name "status.json" | wc -l | tr -d ' ')
        DONE=$(find "$STATE_DIR/swarms" -name "status.json" -exec jq -r '.phase' {} \; 2>/dev/null | grep -c "done" || echo "0")
        ERRORS=$(find "$STATE_DIR/swarms" -name "status.json" -exec jq -r '.phase' {} \; 2>/dev/null | grep -c "error" || echo "0")

        echo "  Summary: $DONE/$TOTAL complete, $ERRORS errors"
    else
        echo "  No state found for run $RUN_ID"
    fi
else
    # List all runs
    echo "── Recent Runs ──────────────────────────────────────"
    if [ -d "$HOME/.claude/multi-swarm/state" ]; then
        for run_dir in "$HOME/.claude/multi-swarm/state"/*/; do
            [ -d "$run_dir" ] || continue
            RID=$(basename "$run_dir")
            SWARM_COUNT=$(find "$run_dir/swarms" -name "status.json" 2>/dev/null | wc -l | tr -d ' ')
            echo "  Run: $RID ($SWARM_COUNT swarms)"
        done
    else
        echo "  No runs found"
    fi
fi

echo ""
echo "╚══════════════════════════════════════════════════════╝"
