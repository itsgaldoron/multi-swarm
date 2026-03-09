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
TOKENS_FILE="$HOME/.claude/multi-swarm/tokens.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Validate required commands are available
require_command jq
require_command git
require_command tmux

# Load OAuth tokens for round-robin assignment
if [ ! -f "$TOKENS_FILE" ]; then
    echo "ERROR: No tokens file at $TOKENS_FILE"
    echo "Create it: echo '[\"sk-ant-oat01-YOUR-TOKEN\"]' > $TOKENS_FILE && chmod 600 $TOKENS_FILE"
    exit 1
fi

# Read tokens into a bash array
TOKENS=()
while IFS= read -r token; do
    TOKENS+=("$token")
done < <(jq -r '.[]' "$TOKENS_FILE")

TOKEN_COUNT=${#TOKENS[@]}
if [ "$TOKEN_COUNT" -eq 0 ]; then
    echo "ERROR: No tokens found in $TOKENS_FILE"
    exit 1
fi

# Validate manifest before using it
validate_manifest "$MANIFEST"

echo "=== Multi-Swarm Launch ==="
echo "Run ID:      $RUN_ID"
echo "Base Branch: $BASE_BRANCH"
echo "Swarms:      $SWARM_COUNT"
echo "Team Size:   $TEAM_SIZE"
echo "Project:     $PROJECT_ROOT"
echo "Tokens:      $TOKEN_COUNT available"
echo "=========================="

# Create state directories
mkdir -p "$STATE_DIR"
for i in $(seq 1 "$SWARM_COUNT"); do
    mkdir -p "$STATE_DIR/swarms/swarm-${i}"
done

# Create tmux session
tmux new-session -d -s "$TMUX_SESSION" -n "monitor" 2>/dev/null || {
    echo "tmux session $TMUX_SESSION already exists, killing and recreating..."
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -n "monitor"
}

echo "Created tmux session: $TMUX_SESSION"

# Cleanup trap — kill tmux session if script is interrupted
swarm_cleanup() {
    echo "Interrupted — cleaning up tmux session..."
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}
trap swarm_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Check if DAG scheduling is needed
# If any swarm declares dependencies, delegate to the DAG scheduler which
# handles topological ordering, cycle detection, and dependency-aware launch.
# Set USE_DAG_SCHEDULER=1 to force DAG mode even without explicit dependencies.
# ---------------------------------------------------------------------------
HAS_DEPS=$(jq '[.swarms[]? | select(.dependencies != null and (.dependencies | length) > 0)] | length' "$MANIFEST")

if [ "$HAS_DEPS" -gt 0 ] || [ "${USE_DAG_SCHEDULER:-0}" = "1" ]; then
    echo ""
    echo "Dependencies detected ($HAS_DEPS swarm(s) with dependencies) — using DAG scheduler"
    # Kill the tmux session we just created; dag-scheduler.sh manages its own
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    DAG_SCRIPT="${SCRIPT_DIR}/dag-scheduler.sh"
    if [ ! -f "$DAG_SCRIPT" ] || [ ! -x "$DAG_SCRIPT" ]; then
        echo "ERROR: DAG scheduler not found or not executable: $DAG_SCRIPT"
        exit 1
    fi
    exec bash "$DAG_SCRIPT" "$RUN_ID" "$BASE_BRANCH" "$SWARM_COUNT" "$TEAM_SIZE" "$MANIFEST"
fi

echo "No dependencies detected — using linear launch"

# ---------------------------------------------------------------------------
# launch_single_swarm — launches one swarm in the existing tmux session
#
# Arguments: $1 = swarm index (1-based)
# Uses globals: RUN_ID, BASE_BRANCH, PROJECT_ROOT, STATE_DIR,
#               TMUX_SESSION, MANIFEST, TEAM_SIZE, TOKENS, TOKEN_COUNT
# ---------------------------------------------------------------------------
launch_single_swarm() {
    local i="$1"

    local SLUG
    SLUG=$(jq -r ".swarms[$((i-1))].slug // \"task-${i}\"" "$MANIFEST")
    local BRANCH="swarm/${RUN_ID}/${i}-${SLUG}"
    local WORKTREE_PATH="${PROJECT_ROOT}/.claude/worktrees/swarm-${RUN_ID}-${i}"
    local STATUS_FILE="$STATE_DIR/swarms/swarm-${i}/status.json"
    local PROMPT_FILE="$STATE_DIR/swarms/swarm-${i}/prompt.md"

    # Assign OAuth token (round-robin across available tokens)
    local TOKEN_INDEX=$(( (i - 1) % TOKEN_COUNT ))
    local SWARM_TOKEN="${TOKENS[$TOKEN_INDEX]}"

    echo ""
    echo "--- Launching Swarm $i: $SLUG (token $((TOKEN_INDEX + 1))/$TOKEN_COUNT) ---"

    # Create git worktree
    echo "  Creating worktree at $WORKTREE_PATH..."
    git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH" 2>/dev/null || {
        echo "  Worktree or branch already exists, removing and recreating..."
        git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
        git branch -D "$BRANCH" 2>/dev/null || true
        git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH"
    }

    # Worktree setup: install deps, copy env files, run project setup
    echo "  Running worktree setup..."
    setup_worktree "$WORKTREE_PATH" "$PROJECT_ROOT"
    echo "  Worktree setup complete"

    # Render swarm prompt
    local SUBTASK
    SUBTASK=$(jq -r ".swarms[$((i-1))].description // \"Subtask ${i}\"" "$MANIFEST")
    local FILE_SCOPE
    FILE_SCOPE=$(jq -r ".swarms[$((i-1))].fileScope // [] | join(\", \")" "$MANIFEST")
    local NO_PARALLEL
    NO_PARALLEL=$(jq -r ".noParallelEdit // [] | join(\", \")" "$MANIFEST")
    local TEST_CMD
    TEST_CMD=$(jq -r '.testCommand // "npm test"' "$MANIFEST")
    local LINT_CMD
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

## MANDATORY Instructions

You are swarm lead #${i}. You MUST follow these steps exactly:

1. Write initial status.json with phase "analyzing" using the Bash tool
2. Analyze the codebase and plan your approach
3. **MANDATORY — DO NOT SKIP**: You MUST use the TeamCreate tool to create an agent team, then use TaskCreate to create tasks, then use the Agent tool to spawn exactly ${TEAM_SIZE} teammates (use subagent_type "general-purpose" for each). Assign tasks to them using TaskUpdate. DO NOT do the implementation work yourself — delegate ALL coding to your teammates. Your role is ONLY to coordinate.
4. Wait for teammates to complete their tasks. Use SendMessage to communicate with them.
5. After all teammates finish, review their work, run tests and lint
6. Commit all changes with prefix [swarm-${i}]
7. Send shutdown requests to all teammates using SendMessage with type "shutdown_request"
8. Write final status.json with phase "done"

CRITICAL: You are a COORDINATOR, not an implementer. If you write code yourself instead of delegating to teammates, you have FAILED your role. You MUST spawn ${TEAM_SIZE} teammates using the Agent tool.
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
    local LAUNCH_SCRIPT="$STATE_DIR/swarms/swarm-${i}/launch.sh"
    # Choose launch mode based on team size
    if [ "${TEAM_SIZE}" -gt 0 ]; then
        # Interactive mode for agent teams (teams require interactive sessions)
        cat > "$LAUNCH_SCRIPT" << LAUNCH
#!/usr/bin/env bash
cd '${WORKTREE_PATH}'
unset CLAUDECODE
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
PROMPT=\$(cat '${PROMPT_FILE}')
CLAUDE_CODE_OAUTH_TOKEN='${SWARM_TOKEN}' claude --dangerously-skip-permissions \\
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
CLAUDE_CODE_OAUTH_TOKEN='${SWARM_TOKEN}' claude --dangerously-skip-permissions \\
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
}

# Launch each swarm linearly (no dependency ordering)
for i in $(seq 1 "$SWARM_COUNT"); do
    launch_single_swarm "$i"

    # Stagger launches to avoid thundering herd
    if [ "$i" -lt "$SWARM_COUNT" ]; then
        echo "  Waiting 2s before next launch..."
        sleep 2
    fi
done

echo ""
echo "=== All $SWARM_COUNT swarms launched ==="
echo "Monitor: tmux attach -t $TMUX_SESSION"
echo "Status:  bash \"\$HOME/.claude/multi-swarm/scripts/monitor.sh\" $RUN_ID"
