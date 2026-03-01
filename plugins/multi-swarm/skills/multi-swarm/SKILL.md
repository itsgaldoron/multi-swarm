---
name: multi-swarm
description: "Launch parallel Claude Code swarms with agent teams, git worktrees, and LiteLLM token gateway"
args:
  - name: task
    description: "The task to decompose and execute across swarms"
    required: true
  - name: swarms
    description: "Number of parallel swarms (default: from config)"
    required: false
  - name: team-size
    description: "Teammates per swarm (default: from config)"
    required: false
  - name: base-branch
    description: "Base branch to create worktrees from (default: current branch)"
    required: false
  - name: dry-run
    description: "Plan and show decomposition without launching (default: false)"
    required: false
user_invocable: true
---

# Multi-Swarm Orchestrator

You are the **meta-lead** for a multi-swarm parallel execution system. You orchestrate N independent Claude Code sessions, each running in its own tmux window with a git worktree, coordinated via file-based IPC.

## Architecture

```
You (Meta-Lead) → tmux session with N windows
  ├─ Window 1: Claude Code (worktree 1, branch swarm/{run}/1-slug)
  │   └─ Agent team: swarm lead + M teammates
  ├─ Window 2: Claude Code (worktree 2, branch swarm/{run}/2-slug)
  │   └─ Agent team: swarm lead + M teammates
  └─ ...
LiteLLM Gateway (localhost:4000) → round-robins all OAuth tokens
```

## Execution Protocol

Follow these 5 phases exactly. Do NOT skip any phase.

---

### Phase 1: Analyze & Decompose

1. **Read configuration**:
   ```bash
   cat ~/.claude/multi-swarm/config.json
   ```
   Also check for project-specific overrides:
   ```bash
   cat .multi-swarm/config.json 2>/dev/null || echo "No project config"
   ```

2. **Determine parameters**:
   - `SWARMS`: from `--swarms` arg, or project config, or global config `defaults.swarms`
   - `TEAM_SIZE`: from `--team-size` arg, or project config, or global config `defaults.teamSize`
   - `BASE_BRANCH`: from `--base-branch` arg, or current branch (`git branch --show-current`)
   - `MAX_RETRIES`: from config `defaults.maxRetries`
   - `POLL_INTERVAL`: from config `defaults.pollIntervalSeconds`
   - `MAX_RUNTIME`: from config `defaults.maxRunTimeMinutes`

3. **Generate run ID**:
   ```bash
   RUN_ID=$(date +%Y%m%d-%H%M%S)-$(head -c 4 /dev/urandom | xxd -p)
   ```

4. **Analyze the task**: Read the project structure, understand the codebase, identify the files and components involved.

5. **Decompose into subtasks**: Break the user's task into N independent subtasks with minimal file overlap. Each subtask should:
   - Be completable independently
   - Have a clear file scope (which files to modify)
   - Not conflict with other subtasks on shared files
   - Include a descriptive slug (e.g., "auth-endpoints", "ui-components")

6. **Identify shared files** that NO swarm should modify in parallel (e.g., lock files, shared constants, schema files). List these in `noParallelEdit`.

7. **Auto-detect project info**:
   ```bash
   # Package manager
   [ -f pnpm-lock.yaml ] && PM="pnpm" || { [ -f yarn.lock ] && PM="yarn" || PM="npm"; }
   # Test command
   TEST_CMD=$(jq -r '.scripts.test // "echo no tests"' package.json 2>/dev/null || echo "echo no tests")
   # Lint command
   LINT_CMD=$(jq -r '.scripts.lint // ""' package.json 2>/dev/null || echo "")
   ```

8. **Write manifest** to `~/.claude/multi-swarm/state/{run-id}/manifest.json`:
   ```json
   {
     "runId": "{run-id}",
     "task": "Original user task description",
     "baseBranch": "main",
     "swarmCount": 4,
     "teamSize": 3,
     "packageManager": "pnpm",
     "testCommand": "pnpm test",
     "lintCommand": "pnpm lint",
     "noParallelEdit": ["lib/constants.ts", "prisma/schema.prisma"],
     "swarms": [
       {
         "id": 1,
         "slug": "auth-endpoints",
         "description": "Implement authentication API endpoints...",
         "fileScope": ["src/auth/*.ts", "src/middleware/auth.ts"],
         "dependencies": []
       },
       {
         "id": 2,
         "slug": "ui-components",
         "description": "Build login and signup UI components...",
         "fileScope": ["src/components/auth/*.tsx"],
         "dependencies": []
       }
     ],
     "createdAt": "ISO timestamp"
   }
   ```

9. **Present decomposition to user** for approval before launching. Show:
   - Number of swarms and team size
   - Each subtask with its slug, description, and file scope
   - Shared files that will be protected
   - Estimated parallelism (total agents)

10. If `--dry-run` was specified, stop here and show the plan.

---

### Phase 2: Setup & Launch

1. **Start LiteLLM gateway** (if not already running):
   ```bash
   PLUGIN_ROOT="$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")"
   bash "${PLUGIN_ROOT}/skills/multi-swarm/scripts/gateway-setup.sh"
   ```
   Verify health:
   ```bash
   curl -sf http://127.0.0.1:4000/health
   ```

2. **Create state directories**:
   ```bash
   STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
   mkdir -p "$STATE_DIR"
   for i in $(seq 1 $SWARMS); do
     mkdir -p "$STATE_DIR/swarms/swarm-${i}"
   done
   ```

3. **Launch swarms** using the orchestrator script:
   ```bash
   bash "${PLUGIN_ROOT}/skills/multi-swarm/scripts/swarm.sh" \
     "$RUN_ID" "$BASE_BRANCH" "$SWARMS" "$TEAM_SIZE" \
     "$STATE_DIR/manifest.json"
   ```

   This script handles:
   - Creating tmux session `swarm-{run-id}`
   - For each swarm: create worktree, render prompt, launch Claude Code in tmux window
   - Staggering launches by 2 seconds

4. **Confirm launch**: Verify all tmux windows are running:
   ```bash
   tmux list-windows -t "swarm-${RUN_ID}"
   ```

---

### Phase 3: Monitor

Poll swarm status every `POLL_INTERVAL` seconds until all swarms complete, fail, or timeout.

1. **Status check loop**:
   ```bash
   STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
   for i in $(seq 1 $SWARMS); do
     STATUS_FILE="$STATE_DIR/swarms/swarm-${i}/status.json"
     if [ -f "$STATUS_FILE" ]; then
       jq '{swarm: '${i}', status: .status, phase: .phase, progress: .progress, commits: .commits}' "$STATUS_FILE"
     else
       echo "{\"swarm\": ${i}, \"status\": \"no-status-file\"}"
     fi
   done
   ```

2. **Report to user**: After each poll, show an aggregated status table:
   ```
   Swarm  Status   Phase      Progress     Commits
   -----  ------   -----      --------     -------
   1      running  working    3/5 tasks    2
   2      running  testing    5/5 tasks    4
   3      done     done       4/4 tasks    3
   4      running  planning   0/3 tasks    0
   ```

3. **Detect failures**:
   - **Crashed**: Check if tmux window still exists
     ```bash
     tmux list-windows -t "swarm-${RUN_ID}" -F "#{window_name}" | grep "swarm-${i}"
     ```
   - **Timed out**: Check if runtime exceeds `MAX_RUNTIME`
   - **Error**: status.json shows `"phase": "error"`

4. **Handle failures**:
   - For crashes/timeouts: Retry up to `MAX_RETRIES` times in the same worktree (preserving any commits made)
   - For errors: Check error details, decide whether to retry or skip
   - Log all failures to `$STATE_DIR/errors.log`

5. **Timeout enforcement**:
   ```bash
   # If swarm exceeds max runtime
   tmux send-keys -t "swarm-${RUN_ID}:swarm-${i}" C-c  # Try graceful stop
   sleep 30
   # If still running, force kill
   tmux send-keys -t "swarm-${RUN_ID}:swarm-${i}" "exit" Enter
   ```

6. **Continue polling** until all swarms are in `done` or `error` state (or retries exhausted).

---

### Phase 4: PR & Merge

Process completed swarms sequentially (in order) to create and merge PRs.

1. **For each completed swarm** (where `status.phase === "done"`), in order:

   a. **Checkout and rebase**:
   ```bash
   BRANCH="swarm/${RUN_ID}/${i}-${SLUG}"
   git checkout "$BRANCH"
   git rebase "$BASE_BRANCH"
   ```

   b. **Push**:
   ```bash
   git push origin "$BRANCH" --force-with-lease
   ```

   c. **Create PR**:
   ```bash
   gh pr create \
     --base "$BASE_BRANCH" \
     --head "$BRANCH" \
     --title "[Swarm ${i}] ${SUMMARY}" \
     --body "$(cat <<EOF
   ## Summary
   ${SUMMARY}

   ## Changes
   ${FILES_CHANGED}

   ## Part of Multi-Swarm Run
   Run ID: \`${RUN_ID}\`
   Swarm: #${i} of ${SWARMS}

   ---
   🤖 Generated by Multi-Swarm orchestrator
   EOF
   )"
   ```

   d. **Merge** (if `autoMerge` is enabled in config):
   ```bash
   gh pr merge --squash --delete-branch
   ```

   e. **Update base** before next swarm:
   ```bash
   git checkout "$BASE_BRANCH"
   git pull origin "$BASE_BRANCH"
   ```

2. **Handle merge conflicts**:
   - If rebase fails: leave PR open, log conflict, continue with next swarm
   - Report all conflicts at the end
   - Suggest manual resolution steps

3. **Track merge results** in `$STATE_DIR/merge-results.json`:
   ```json
   {
     "merged": [1, 3],
     "conflicted": [2],
     "skipped": [4],
     "prUrls": {
       "1": "https://github.com/...",
       "3": "https://github.com/..."
     }
   }
   ```

---

### Phase 5: Cleanup

1. **Kill tmux session**:
   ```bash
   tmux kill-session -t "swarm-${RUN_ID}" 2>/dev/null || true
   ```

2. **Run teardown scripts** for each worktree:
   ```bash
   for i in $(seq 1 $SWARMS); do
     WORKTREE=".claude/worktrees/swarm-${RUN_ID}-${i}"
     if [ -d "$WORKTREE" ]; then
       WORKTREE_PATH="$WORKTREE" bash "${PLUGIN_ROOT}/skills/multi-swarm/scripts/worktree-teardown.sh"
     fi
   done
   ```

3. **Remove worktrees**:
   ```bash
   for i in $(seq 1 $SWARMS); do
     WORKTREE=".claude/worktrees/swarm-${RUN_ID}-${i}"
     git worktree remove "$WORKTREE" --force 2>/dev/null || true
   done
   git worktree prune
   ```

4. **Clean up branches** for merged swarms:
   ```bash
   for i in ${MERGED_SWARMS}; do
     BRANCH="swarm/${RUN_ID}/${i}-${SLUG}"
     git branch -D "$BRANCH" 2>/dev/null || true
   done
   ```

5. **Stop gateway** if no other runs are active:
   ```bash
   OTHER_RUNS=$(find "$HOME/.claude/multi-swarm/state" -maxdepth 1 -type d | wc -l)
   if [ "$OTHER_RUNS" -le 1 ]; then
     GATEWAY_PID=$(cat "$HOME/.claude/multi-swarm/gateway.pid" 2>/dev/null)
     if [ -n "$GATEWAY_PID" ]; then
       kill "$GATEWAY_PID" 2>/dev/null || true
       rm "$HOME/.claude/multi-swarm/gateway.pid"
     fi
   fi
   ```

6. **Write final summary** to `$STATE_DIR/result.json`:
   ```json
   {
     "runId": "{run-id}",
     "status": "completed",
     "swarms": {
       "total": 4,
       "succeeded": 3,
       "failed": 1,
       "merged": 3
     },
     "totalCommits": 12,
     "totalFilesChanged": 15,
     "duration": "45m 23s",
     "mergeResults": { ... },
     "errors": [ ... ],
     "completedAt": "ISO timestamp"
   }
   ```

7. **Report to user**: Show final summary with:
   - Overall success/failure status
   - Per-swarm results
   - Merged PR URLs
   - Any conflicts or errors that need manual attention
   - Total duration and cost estimate

---

## Error Recovery

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Token rate-limited | Gateway handles automatically | Circuit-break key for 60s, route to another |
| All tokens exhausted | Gateway returns 429 | Wait for cooldown, alert user |
| Worktree setup fails | Setup script exits non-zero | Try default setup; if both fail, skip swarm |
| Swarm process crash | tmux window gone | Retry up to MAX_RETRIES in same worktree |
| Swarm timeout | Exceeds maxRunTimeMinutes | SIGTERM → 30s → force kill, preserve commits |
| Tests fail (quality gate) | quality-gate.sh exits 2 | Block task completion, agent must fix |
| Merge conflict | `git rebase` or `gh pr merge` fails | Leave PR open, continue others, report |
| Partial completion | Some swarms fail | Merge successes, report failures with details |

---

## Usage Examples

```bash
# Basic: decompose and execute across 4 swarms
/multi-swarm "Add user authentication with login, signup, and password reset"

# Custom swarm count and team size
/multi-swarm "Refactor the API layer" --swarms 6 --team-size 4

# Dry run to preview decomposition
/multi-swarm "Add dark mode support" --dry-run

# Specify base branch
/multi-swarm "Fix all lint errors" --base-branch develop --swarms 8 --team-size 2
```
