#!/usr/bin/env bash
set -euo pipefail

# Multi-Swarm tmux Orchestrator
# Usage: swarm.sh <run-id> <base-branch> <swarm-count> <team-size> <manifest-path>

RUN_ID="${1:?Usage: swarm.sh <run-id> <base-branch> <swarm-count> <team-size> <manifest-path>}"
BASE_BRANCH="${2:-main}"
SWARM_COUNT="${3:-4}"
TEAM_SIZE="${4:-3}"
MANIFEST="${5:?Manifest path required}"

STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
TMUX_SESSION="swarm-${RUN_ID}"
GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"

# Read gateway config
GATEWAY_PORT=$(jq -r '.gateway.port // 4000' "$GLOBAL_CONFIG" 2>/dev/null || echo "4000")
MASTER_KEY=$(jq -r '.gateway.masterKey // "sk-swarm-master"' "$GLOBAL_CONFIG" 2>/dev/null || echo "sk-swarm-master")

echo "=== Multi-Swarm Launch ==="
echo "Run ID:      $RUN_ID"
echo "Base Branch: $BASE_BRANCH"
echo "Swarms:      $SWARM_COUNT"
echo "Team Size:   $TEAM_SIZE"
echo "Project:     $PROJECT_ROOT"
echo "=========================="

# Create state directories
mkdir -p "$STATE_DIR"
for i in $(seq 1 "$SWARM_COUNT"); do
    mkdir -p "$STATE_DIR/swarms/swarm-${i}"
done

# Verify gateway is running
if ! curl -sf -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${GATEWAY_PORT}/health" >/dev/null 2>&1; then
    echo "ERROR: LiteLLM gateway not running on port $GATEWAY_PORT"
    echo "Start it with: bash scripts/gateway-setup.sh"
    exit 1
fi

# Create tmux session
tmux new-session -d -s "$TMUX_SESSION" -n "monitor" 2>/dev/null || {
    echo "tmux session $TMUX_SESSION already exists, killing and recreating..."
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -n "monitor"
}

echo "Created tmux session: $TMUX_SESSION"

# Launch each swarm
for i in $(seq 1 "$SWARM_COUNT"); do
    SLUG=$(jq -r ".swarms[$((i-1))].slug // \"task-${i}\"" "$MANIFEST")
    BRANCH="swarm/${RUN_ID}/${i}-${SLUG}"
    WORKTREE_PATH="${PROJECT_ROOT}/.claude/worktrees/swarm-${RUN_ID}-${i}"
    STATUS_FILE="$STATE_DIR/swarms/swarm-${i}/status.json"
    PROMPT_FILE="$STATE_DIR/swarms/swarm-${i}/prompt.md"

    echo ""
    echo "--- Launching Swarm $i: $SLUG ---"

    # Create git worktree
    echo "  Creating worktree at $WORKTREE_PATH..."
    git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH" 2>/dev/null || {
        echo "  Worktree or branch already exists, removing and recreating..."
        git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
        git branch -D "$BRANCH" 2>/dev/null || true
        git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH"
    }

    # Render swarm prompt
    SUBTASK=$(jq -r ".swarms[$((i-1))].description // \"Subtask ${i}\"" "$MANIFEST")
    FILE_SCOPE=$(jq -r ".swarms[$((i-1))].fileScope // [] | join(\", \")" "$MANIFEST")
    NO_PARALLEL=$(jq -r ".noParallelEdit // [] | join(\", \")" "$MANIFEST")
    TEST_CMD=$(jq -r '.testCommand // "npm test"' "$MANIFEST")
    LINT_CMD=$(jq -r '.lintCommand // ""' "$MANIFEST")

    cat > "$PROMPT_FILE" << PROMPT
# Swarm ${i} — ${SLUG}

## Identity
- **Swarm ID**: ${i}
- **Run ID**: ${RUN_ID}
- **Branch**: ${BRANCH}
- **Base Branch**: ${BASE_BRANCH}

## Task
${SUBTASK}

## Configuration
- **Worktree Path**: ${WORKTREE_PATH}
- **Status File**: ${STATUS_FILE}
- **Team Size**: ${TEAM_SIZE}
- **Test Command**: ${TEST_CMD}
- **Lint Command**: ${LINT_CMD}

## Scope
- **Files to modify**: ${FILE_SCOPE}
- **Do NOT modify (shared)**: ${NO_PARALLEL}

## Instructions
You are swarm lead #${i}. Follow the swarm-lead agent protocol:
1. Write initial status.json with phase "analyzing"
2. Analyze the codebase and plan your approach
3. Create an agent team and break work into tasks for ${TEAM_SIZE} teammates
4. Coordinate teammates, monitor progress, ensure quality
5. Run tests and lint before finishing
6. Commit all changes with prefix [swarm-${i}]
7. Write final status.json with phase "done"
PROMPT

    # Initialize status.json
    cat > "$STATUS_FILE" << STATUS
{
  "status": "pending",
  "phase": "launching",
  "teamSize": ${TEAM_SIZE},
  "progress": "0/0",
  "commits": 0,
  "filesChanged": [],
  "summary": "",
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "error": null
}
STATUS

    # Create tmux window for this swarm
    tmux new-window -t "$TMUX_SESSION" -n "swarm-${i}"

    # Build the launch script (avoids quoting issues with tmux send-keys)
    LAUNCH_SCRIPT="$STATE_DIR/swarms/swarm-${i}/launch.sh"
    # Choose launch mode based on team size
    if [ "${TEAM_SIZE}" -gt 0 ]; then
        # Interactive mode for agent teams (teams require interactive sessions)
        cat > "$LAUNCH_SCRIPT" << LAUNCH
#!/usr/bin/env bash
cd '${WORKTREE_PATH}'
unset CLAUDECODE
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
PROMPT=\$(cat '${PROMPT_FILE}')
claude --dangerously-skip-permissions \\
       --model opus \\
       --append-system-prompt "\$PROMPT" \\
       "Execute the task described in your system prompt. Work autonomously — do not ask questions, just execute. When fully done, type /exit."
LAUNCH
    else
        # Non-interactive print mode for solo swarms (no teammates needed)
        cat > "$LAUNCH_SCRIPT" << LAUNCH
#!/usr/bin/env bash
cd '${WORKTREE_PATH}'
unset CLAUDECODE
PROMPT=\$(cat '${PROMPT_FILE}')
claude --dangerously-skip-permissions \\
       --model opus \\
       --append-system-prompt "\$PROMPT" \\
       -p "Execute the task described in your system prompt. Do not ask questions — just do it."
LAUNCH
    fi
    chmod +x "$LAUNCH_SCRIPT"

    # Launch via script to avoid tmux quoting issues
    tmux send-keys -t "${TMUX_SESSION}:swarm-${i}" "bash '${LAUNCH_SCRIPT}'" Enter

    # Record PID (will be populated after claude starts)
    echo "$$" > "$STATE_DIR/swarms/swarm-${i}/pid.txt"

    echo "  Swarm $i launched in tmux window"

    # Stagger launches to avoid thundering herd
    if [ "$i" -lt "$SWARM_COUNT" ]; then
        echo "  Waiting 2s before next launch..."
        sleep 2
    fi
done

echo ""
echo "=== All $SWARM_COUNT swarms launched ==="
echo "Monitor: tmux attach -t $TMUX_SESSION"
echo "Status:  bash scripts/monitor.sh $RUN_ID"
