#!/usr/bin/env bash
set -euo pipefail

# DAG Scheduler for Multi-Swarm
# Launches swarms respecting dependency ordering declared in manifest.json.
# Instead of launching all swarms linearly, this script builds a directed
# acyclic graph (DAG) from the manifest's dependency declarations, validates
# it (cycle detection), topologically sorts it, and then launches swarms only
# when all their prerequisites have completed.
#
# Usage: dag-scheduler.sh <run-id> <base-branch> <swarm-count> <team-size> <manifest-path>
#
# The manifest must contain a "swarms" array where each entry may include a
# "dependencies" array of swarm IDs that must complete before it can start:
#
#   {
#     "swarms": [
#       {"id": 1, "slug": "auth-api", "dependencies": []},
#       {"id": 2, "slug": "auth-ui", "dependencies": [1]},
#       {"id": 3, "slug": "tests",   "dependencies": [1, 2]}
#     ]
#   }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
RUN_ID="${1:?Usage: dag-scheduler.sh <run-id> <base-branch> <swarm-count> <team-size> <manifest-path>}"
BASE_BRANCH="${2:-main}"
SWARM_COUNT="${3:-4}"
TEAM_SIZE="${4:-3}"
MANIFEST="${5:?Manifest path required}"

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
TMUX_SESSION="swarm-${RUN_ID}"
TOKENS_FILE="$HOME/.claude/multi-swarm/tokens.json"
POLL_INTERVAL="${DAG_POLL_INTERVAL:-10}"   # seconds between status polls
LOG_FILE="$STATE_DIR/dag-scheduler.log"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() {
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Load OAuth tokens (round-robin assignment, same as swarm.sh)
# ---------------------------------------------------------------------------
load_tokens() {
    if [ ! -f "$TOKENS_FILE" ]; then
        echo "ERROR: No tokens file at $TOKENS_FILE"
        echo "Create it: echo '[\"sk-ant-oat01-...\", ...]' > $TOKENS_FILE && chmod 600 $TOKENS_FILE"
        exit 1
    fi

    TOKENS=()
    while IFS= read -r token; do
        TOKENS+=("$token")
    done < <(jq -r '.[]' "$TOKENS_FILE")

    TOKEN_COUNT=${#TOKENS[@]}
    if [ "$TOKEN_COUNT" -eq 0 ]; then
        echo "ERROR: No tokens found in $TOKENS_FILE"
        exit 1
    fi
}

# ===========================================================================
# DAG construction & validation
# ===========================================================================

# ---------------------------------------------------------------------------
# parse_dependencies — reads manifest.json and builds adjacency list
#
# Populates the following associative arrays:
#   SWARM_SLUG[id]        — slug for each swarm
#   SWARM_DEPS[id]        — space-separated list of dependency IDs
#   SWARM_DEPENDENTS[id]  — space-separated list of IDs that depend on this swarm
#   SWARM_IDS             — ordered array of all swarm IDs
# ---------------------------------------------------------------------------
declare -A SWARM_SLUG
declare -A SWARM_DEPS
declare -A SWARM_DEPENDENTS
declare -a SWARM_IDS=()

parse_dependencies() {
    log "Parsing dependencies from $MANIFEST"

    local count
    count=$(jq '.swarms | length' "$MANIFEST")

    for (( idx=0; idx<count; idx++ )); do
        local id slug deps_json
        id=$(jq -r ".swarms[$idx].id // $((idx+1))" "$MANIFEST")
        slug=$(jq -r ".swarms[$idx].slug // \"task-${id}\"" "$MANIFEST")
        deps_json=$(jq -r ".swarms[$idx].dependencies // [] | map(tostring) | join(\" \")" "$MANIFEST")

        SWARM_IDS+=("$id")
        SWARM_SLUG[$id]="$slug"
        SWARM_DEPS[$id]="${deps_json}"

        # Initialise dependents list if not already set
        if [ -z "${SWARM_DEPENDENTS[$id]+x}" ]; then
            SWARM_DEPENDENTS[$id]=""
        fi

        # Build reverse adjacency (dependents) for quick look-ups
        for dep in $deps_json; do
            if [ -z "${SWARM_DEPENDENTS[$dep]+x}" ]; then
                SWARM_DEPENDENTS[$dep]=""
            fi
            SWARM_DEPENDENTS[$dep]="${SWARM_DEPENDENTS[$dep]} $id"
        done

        if [ -n "$deps_json" ]; then
            log "  Swarm $id ($slug) depends on: $deps_json"
        else
            log "  Swarm $id ($slug) has no dependencies (root node)"
        fi
    done

    log "Parsed ${#SWARM_IDS[@]} swarm(s)"
}

# ---------------------------------------------------------------------------
# validate_dag — detects cycles using iterative DFS with colouring
#
# Uses three colours per node:
#   0 = white (unvisited), 1 = grey (in current path), 2 = black (done)
#
# Returns 0 on success, exits with error message on cycle detection.
# ---------------------------------------------------------------------------
validate_dag() {
    log "Validating DAG (cycle detection)..."

    declare -A colour
    for id in "${SWARM_IDS[@]}"; do
        colour[$id]=0
    done

    for start in "${SWARM_IDS[@]}"; do
        [ "${colour[$start]}" -ne 0 ] && continue

        # Iterative DFS using an explicit stack. Each stack entry is "id:action"
        # where action is "enter" or "exit".
        local stack=("${start}:enter")

        while [ ${#stack[@]} -gt 0 ]; do
            local top="${stack[-1]}"
            unset 'stack[-1]'

            local node="${top%%:*}"
            local action="${top##*:}"

            if [ "$action" = "exit" ]; then
                colour[$node]=2
                continue
            fi

            if [ "${colour[$node]}" -eq 1 ]; then
                # Already grey — skip (we pushed an exit marker already)
                continue
            fi

            if [ "${colour[$node]}" -eq 2 ]; then
                continue
            fi

            colour[$node]=1
            stack+=("${node}:exit")

            for dep in ${SWARM_DEPS[$node]}; do
                if [ "${colour[$dep]}" -eq 1 ]; then
                    log "ERROR: Cycle detected involving swarm $dep (dependency of swarm $node)"
                    echo "ERROR: Dependency cycle detected — swarm $node depends on swarm $dep which is still in the current traversal path."
                    exit 1
                fi
                if [ "${colour[$dep]}" -eq 0 ]; then
                    stack+=("${dep}:enter")
                fi
            done
        done
    done

    log "DAG validation passed — no cycles detected"
}

# ---------------------------------------------------------------------------
# topological_sort — returns a valid execution order respecting dependencies
#
# Uses Kahn's algorithm (BFS-based) for a deterministic, stable ordering.
# Result is stored in the TOPO_ORDER array.
# ---------------------------------------------------------------------------
declare -a TOPO_ORDER=()

topological_sort() {
    log "Computing topological sort..."

    declare -A in_degree
    for id in "${SWARM_IDS[@]}"; do
        in_degree[$id]=0
    done

    # Count incoming edges
    for id in "${SWARM_IDS[@]}"; do
        for dep in ${SWARM_DEPS[$id]}; do
            in_degree[$id]=$(( ${in_degree[$id]} + 1 ))
        done
    done

    # Seed the queue with nodes that have zero in-degree (root nodes)
    local queue=()
    for id in "${SWARM_IDS[@]}"; do
        if [ "${in_degree[$id]}" -eq 0 ]; then
            queue+=("$id")
        fi
    done

    TOPO_ORDER=()

    while [ ${#queue[@]} -gt 0 ]; do
        # Pop from front (FIFO for stable ordering)
        local node="${queue[0]}"
        queue=("${queue[@]:1}")
        TOPO_ORDER+=("$node")

        # Reduce in-degree for dependents
        for dependent in ${SWARM_DEPENDENTS[$node]}; do
            in_degree[$dependent]=$(( ${in_degree[$dependent]} - 1 ))
            if [ "${in_degree[$dependent]}" -eq 0 ]; then
                queue+=("$dependent")
            fi
        done
    done

    if [ "${#TOPO_ORDER[@]}" -ne "${#SWARM_IDS[@]}" ]; then
        log "ERROR: Topological sort incomplete — possible cycle not caught by validation"
        exit 1
    fi

    log "Topological order: ${TOPO_ORDER[*]}"
}

# ===========================================================================
# Swarm launching (mirrors swarm.sh launch logic)
# ===========================================================================

# Tracks which swarms have been launched and which are done
declare -A LAUNCHED   # id -> 1 if launched
declare -A COMPLETED  # id -> 1 if done

# ---------------------------------------------------------------------------
# is_swarm_done — checks if a swarm's status.json shows phase "done"
# ---------------------------------------------------------------------------
is_swarm_done() {
    local id="$1"
    local status_file="$STATE_DIR/swarms/swarm-${id}/status.json"

    if [ ! -f "$status_file" ]; then
        return 1
    fi

    local phase
    phase=$(jq -r '.phase // "unknown"' "$status_file" 2>/dev/null || echo "unknown")
    [ "$phase" = "done" ]
}

# ---------------------------------------------------------------------------
# get_ready_swarms — returns swarms whose dependencies are all satisfied
#                    and that have not yet been launched
# ---------------------------------------------------------------------------
get_ready_swarms() {
    local ready=()

    for id in "${SWARM_IDS[@]}"; do
        # Skip already launched
        [ -n "${LAUNCHED[$id]+x}" ] && continue

        local all_deps_met=true
        for dep in ${SWARM_DEPS[$id]}; do
            if [ -z "${COMPLETED[$dep]+x}" ]; then
                all_deps_met=false
                break
            fi
        done

        if $all_deps_met; then
            ready+=("$id")
        fi
    done

    echo "${ready[*]}"
}

# ---------------------------------------------------------------------------
# launch_swarm — launches a single swarm (replicates the loop body from swarm.sh)
#
# Creates worktree, renders prompt, initialises status.json, launches in tmux.
# ---------------------------------------------------------------------------
launch_swarm() {
    local i="$1"
    local idx=$((i - 1))

    local SLUG="${SWARM_SLUG[$i]}"
    local BRANCH="swarm/${RUN_ID}/${i}-${SLUG}"
    local WORKTREE_PATH="${PROJECT_ROOT}/.claude/worktrees/swarm-${RUN_ID}-${i}"
    local STATUS_FILE="$STATE_DIR/swarms/swarm-${i}/status.json"
    local PROMPT_FILE="$STATE_DIR/swarms/swarm-${i}/prompt.md"

    # Assign OAuth token (round-robin)
    local TOKEN_INDEX=$(( (i - 1) % TOKEN_COUNT ))
    local SWARM_TOKEN="${TOKENS[$TOKEN_INDEX]}"

    log "Launching swarm $i: $SLUG (token $((TOKEN_INDEX + 1))/$TOKEN_COUNT)"

    # Create git worktree
    log "  Creating worktree at $WORKTREE_PATH..."
    git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH" 2>/dev/null || {
        log "  Worktree or branch already exists, removing and recreating..."
        git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
        git branch -D "$BRANCH" 2>/dev/null || true
        git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_BRANCH"
    }

    # Inline worktree setup (same as swarm.sh)
    log "  Running worktree setup..."
    (
        cd "$WORKTREE_PATH"
        GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"
        INSTALL_DEPS=$(jq -r '.setup.installDependencies // true' "$GLOBAL_CONFIG" 2>/dev/null || echo "true")
        COPY_ENV=$(jq -r '.setup.copyEnvFiles // true' "$GLOBAL_CONFIG" 2>/dev/null || echo "true")
        ENV_FILES=$(jq -r '.setup.envFilesToCopy // [".env", ".env.local", ".env.development.local"] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || echo -e ".env\n.env.local\n.env.development.local")

        if [ "$INSTALL_DEPS" = "true" ]; then
            if [ -f "pnpm-lock.yaml" ]; then
                pnpm install --frozen-lockfile 2>/dev/null || pnpm install
            elif [ -f "yarn.lock" ]; then
                yarn install --frozen-lockfile 2>/dev/null || yarn install
            elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
                bun install --frozen-lockfile 2>/dev/null || bun install
            elif [ -f "package-lock.json" ]; then
                npm ci 2>/dev/null || npm install
            elif [ -f "Cargo.toml" ]; then
                cargo build 2>/dev/null || true
            elif [ -f "go.mod" ]; then
                go mod download 2>/dev/null || true
            elif [ -f "requirements.txt" ]; then
                pip install -r requirements.txt 2>/dev/null || true
            elif [ -f "pyproject.toml" ]; then
                if command -v uv &>/dev/null; then
                    uv sync 2>/dev/null || true
                elif [ -f "poetry.lock" ]; then
                    poetry install 2>/dev/null || true
                else
                    pip install -e . 2>/dev/null || true
                fi
            elif [ -f "Gemfile" ]; then
                bundle install 2>/dev/null || true
            fi
        fi

        if [ "$COPY_ENV" = "true" ] && [ -d "$PROJECT_ROOT" ]; then
            echo "$ENV_FILES" | while read -r envfile; do
                if [ -n "$envfile" ] && [ -f "${PROJECT_ROOT}/${envfile}" ]; then
                    cp "${PROJECT_ROOT}/${envfile}" "${WORKTREE_PATH}/${envfile}"
                    log "  Copied ${envfile} from source project"
                fi
            done
        fi

        # Run project-specific setup if it exists
        if [ -f "${PROJECT_ROOT}/.multi-swarm/setup.sh" ]; then
            bash "${PROJECT_ROOT}/.multi-swarm/setup.sh" "$WORKTREE_PATH"
        fi
    )
    log "  Worktree setup complete"

    # Build dependency context for the prompt
    local dep_context=""
    if [ -n "${SWARM_DEPS[$i]}" ]; then
        dep_context="
## Dependencies
This swarm depends on the following swarms which have already completed:
"
        for dep in ${SWARM_DEPS[$i]}; do
            dep_context+="- Swarm $dep (${SWARM_SLUG[$dep]}) — branch: swarm/${RUN_ID}/${dep}-${SWARM_SLUG[$dep]}
"
        done
        dep_context+="
You may reference or build upon work done in those branches.
"
    fi

    # Render swarm prompt
    local SUBTASK
    SUBTASK=$(jq -r ".swarms[$idx].description // \"Subtask ${i}\"" "$MANIFEST")
    local FILE_SCOPE
    FILE_SCOPE=$(jq -r ".swarms[$idx].fileScope // [] | join(\", \")" "$MANIFEST")
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
${dep_context}
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

    # Build launch script (avoids quoting issues with tmux send-keys)
    local LAUNCH_SCRIPT="$STATE_DIR/swarms/swarm-${i}/launch.sh"
    if [ "${TEAM_SIZE}" -gt 0 ]; then
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

    # Launch via script in tmux
    tmux send-keys -t "${TMUX_SESSION}:swarm-${i}" "bash '${LAUNCH_SCRIPT}'" Enter

    # Record PID
    echo "$$" > "$STATE_DIR/swarms/swarm-${i}/pid.txt"

    LAUNCHED[$i]=1
    log "  Swarm $i launched in tmux window"
}

# ---------------------------------------------------------------------------
# check_rebalance — checks for newly completed swarms and logs resource
#                   availability for potential reassignment
# ---------------------------------------------------------------------------
check_rebalance() {
    for id in "${SWARM_IDS[@]}"; do
        # Only check launched, non-completed swarms
        [ -z "${LAUNCHED[$id]+x}" ] && continue
        [ -n "${COMPLETED[$id]+x}" ] && continue

        if is_swarm_done "$id"; then
            COMPLETED[$id]=1
            local slug="${SWARM_SLUG[$id]}"
            local worktree="${PROJECT_ROOT}/.claude/worktrees/swarm-${RUN_ID}-${id}"
            local token_idx=$(( (id - 1) % TOKEN_COUNT ))

            log "REBALANCE: Swarm $id ($slug) completed"
            log "  -> Worktree available: $worktree"
            log "  -> Token slot $((token_idx + 1)) available for reassignment"

            # Notify dependents that a blocker has cleared
            for dependent in ${SWARM_DEPENDENTS[$id]}; do
                log "  -> Unblocked potential launch of swarm $dependent (${SWARM_SLUG[$dependent]})"
            done
        fi
    done
}

# ===========================================================================
# Main scheduling loop
# ===========================================================================

# ---------------------------------------------------------------------------
# poll_and_schedule — main loop that polls status and launches ready swarms
#
# Runs until all swarms have completed. Each iteration:
#   1. Checks for newly completed swarms (rebalancing)
#   2. Determines which swarms are now ready to launch
#   3. Launches ready swarms with a small stagger
#   4. Sleeps for POLL_INTERVAL seconds
# ---------------------------------------------------------------------------
poll_and_schedule() {
    local total=${#SWARM_IDS[@]}
    local iteration=0

    log "Starting DAG scheduler main loop (poll interval: ${POLL_INTERVAL}s)"

    while [ "${#COMPLETED[@]}" -lt "$total" ]; do
        iteration=$((iteration + 1))

        # Check for newly completed swarms and log rebalancing opportunities
        check_rebalance

        # Find swarms ready to launch
        local ready
        ready=$(get_ready_swarms)

        if [ -n "$ready" ]; then
            for id in $ready; do
                log "Scheduling swarm $id (${SWARM_SLUG[$id]}) — all dependencies satisfied"
                launch_swarm "$id"

                # Stagger launches to avoid thundering herd
                sleep 2
            done
        fi

        # Progress report
        local launched_count=${#LAUNCHED[@]}
        local completed_count=${#COMPLETED[@]}
        log "Poll #${iteration}: ${completed_count}/${total} done, ${launched_count}/${total} launched"

        # If all launched but not all done, just wait
        if [ "$completed_count" -lt "$total" ]; then
            sleep "$POLL_INTERVAL"
        fi
    done

    log "All $total swarms completed!"
}

# ===========================================================================
# Entrypoint
# ===========================================================================
main() {
    echo "=== Multi-Swarm DAG Scheduler ==="
    echo "Run ID:        $RUN_ID"
    echo "Base Branch:   $BASE_BRANCH"
    echo "Swarms:        $SWARM_COUNT"
    echo "Team Size:     $TEAM_SIZE"
    echo "Project:       $PROJECT_ROOT"
    echo "Poll Interval: ${POLL_INTERVAL}s"
    echo "================================="

    # Load tokens
    load_tokens
    echo "Tokens: $TOKEN_COUNT available"

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
    log "Created tmux session: $TMUX_SESSION"

    # Build the DAG
    parse_dependencies
    validate_dag
    topological_sort

    echo ""
    echo "Execution order: ${TOPO_ORDER[*]}"
    echo ""

    # Initialise tracking maps
    for id in "${SWARM_IDS[@]}"; do
        unset "LAUNCHED[$id]" 2>/dev/null || true
        unset "COMPLETED[$id]" 2>/dev/null || true
    done

    # Run the scheduling loop
    poll_and_schedule

    echo ""
    echo "=== All $SWARM_COUNT swarms completed ==="
    echo "Monitor: tmux attach -t $TMUX_SESSION"
    echo "Status:  bash \"\$HOME/.claude/multi-swarm/scripts/monitor.sh\" $RUN_ID"
    echo "Log:     $LOG_FILE"
}

main "$@"
