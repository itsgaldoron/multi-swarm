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
Shared: lib/common.sh → logging, git helpers, retry logic used by all scripts
```

## Execution Protocol

Follow these 5 phases exactly. Do NOT skip any phase.

---

### Phase 1: Analyze & Decompose

1. **Ensure config directory and defaults exist**:
   ```bash
   mkdir -p ~/.claude/multi-swarm
   # Create default config if missing
   if [ ! -f ~/.claude/multi-swarm/config.json ]; then
     cat > ~/.claude/multi-swarm/config.json << 'DEFAULTCFG'
   {
     "defaults": {
       "swarms": 4,
       "teamSize": 3,
       "model": "opus",
       "maxRetries": 2,
       "pollIntervalSeconds": 30,
       "maxRunTimeMinutes": 120,
       "autoMerge": true
     },
     "gateway": {
       "port": 4000,
       "masterKey": "ms-gateway-key",
       "routingStrategy": "usage-based-routing-v2",
       "cooldownSeconds": 60
     },
     "setup": {
       "autoDetectPackageManager": true,
       "installDependencies": true,
       "copyEnvFiles": true,
       "envFilesToCopy": [".env", ".env.local", ".env.development.local"]
     },
     "merge": {
       "strategy": "squash",
       "deleteAfterMerge": true,
       "conflictBehavior": "skip-and-report"
     }
   }
   DEFAULTCFG
   fi
   ```

   **Check for tokens** (required — the only thing the user must provide):
   ```bash
   if [ ! -f ~/.claude/multi-swarm/tokens.json ]; then
     echo "No tokens found. Please create ~/.claude/multi-swarm/tokens.json with at least one Anthropic OAuth token (sk-ant-oat01-* format):"
     echo '  echo '\''["sk-ant-oat01-YOUR-TOKEN"]'\'' > ~/.claude/multi-swarm/tokens.json && chmod 600 ~/.claude/multi-swarm/tokens.json'
     exit 1
   fi
   ```

   **Read configuration**:
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

   **Decomposition best practices**:

   Split by **feature layer** (good) rather than by component type (bad):
   ```
   ✅ Good — split by feature:
     Swarm 1: "auth-system" → auth routes, auth middleware, auth tests
     Swarm 2: "billing-system" → billing routes, billing service, billing tests
     Swarm 3: "notifications" → notification service, email templates, notification tests

   ❌ Bad — split by component type:
     Swarm 1: "all-routes" → every route file (conflicts likely)
     Swarm 2: "all-tests" → every test file (blocked until routes exist)
     Swarm 3: "all-middleware" → every middleware (cross-cutting, high overlap)
   ```

   **Estimating task complexity**: Balance work across swarms by estimating the number of files and logical changes per subtask. A swarm handling 2 new files with clear scope is lighter than one modifying 8 existing files with cross-cutting concerns. Aim for roughly equal effort per swarm — if one subtask is 3x larger than others, split it further or merge the smaller ones.

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
   PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(find ~/.claude/plugins/cache -path '*/multi-swarm-marketplace/multi-swarm/*/skills' -type d 2>/dev/null | head -1 | sed 's|/skills$||')}"
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

3. **Launch swarms** using the orchestrator script (uses `PLUGIN_ROOT` from step 1):
   ```bash
   bash "${PLUGIN_ROOT}/skills/multi-swarm/scripts/swarm.sh" \
     "$RUN_ID" "$BASE_BRANCH" "$SWARMS" "$TEAM_SIZE" \
     "$STATE_DIR/manifest.json"
   ```

   This script handles:
   - Creating tmux session `swarm-{run-id}`
   - **Automatic DAG detection**: If any swarm declares `dependencies`, swarm.sh delegates to `dag-scheduler.sh` for dependency-aware launching (see [DAG Scheduling](#dag-scheduling) below)
   - For linear (no-dependency) runs: create worktree, render prompt, launch Claude Code in tmux window
   - Staggering launches by 2 seconds

4. **Confirm launch**: Verify all tmux windows are running:
   ```bash
   tmux list-windows -t "swarm-${RUN_ID}"
   ```

5. **Launch streaming merge watcher** (background):
   ```bash
   bash "${PLUGIN_ROOT}/skills/multi-swarm/scripts/streaming-merge.sh" \
     "$RUN_ID" "$BASE_BRANCH" "$SWARMS" "$STATE_DIR/manifest.json" \
     > "$STATE_DIR/streaming-merge.log" 2>&1 &
   STREAMING_MERGE_PID=$!
   echo "$STREAMING_MERGE_PID" > "$STATE_DIR/streaming-merge.pid"
   ```
   This starts the merge-as-you-go pipeline. PRs will be created and merged as soon as each swarm finishes, without waiting for all swarms.

---

### DAG Scheduling (Dependency-Aware Launch) {#dag-scheduling}

When swarms declare `dependencies` in the manifest (see the `dependencies` field in the manifest example above), the system automatically uses `dag-scheduler.sh` instead of launching all swarms simultaneously. This enables ordered execution where some swarms wait for prerequisites to complete before starting.

**How it works:**

1. **Automatic detection**: `swarm.sh` inspects the manifest for any swarm with a non-empty `dependencies` array. If found, it delegates to `dag-scheduler.sh` via `exec`. You can also force DAG mode by setting `USE_DAG_SCHEDULER=1`.

2. **Graph validation**: The DAG scheduler builds a directed acyclic graph from the dependency declarations, then validates it with cycle detection (iterative DFS). If a cycle is found, the run aborts with an error.

3. **Topological ordering**: Swarms are topologically sorted using Kahn's algorithm to determine a valid execution order.

4. **Dependency-aware launching**:
   - Swarms with no dependencies (root nodes) launch immediately
   - Dependent swarms launch only after **all** their prerequisites have completed
   - Multiple independent swarms at the same level launch in parallel

5. **Dynamic rebalancing**: When a swarm completes, the scheduler:
   - Logs that the swarm's token slot and worktree are available for reassignment
   - Checks which downstream swarms are now unblocked
   - Launches newly-ready swarms with a 2-second stagger

6. **Dependency context**: Swarms launched after their prerequisites receive extra context in their prompt listing the completed dependency branches, so they can reference or build upon that work.

**Example manifest with dependencies:**

```json
{
  "swarms": [
    {"id": 1, "slug": "auth-api", "dependencies": []},
    {"id": 2, "slug": "auth-ui", "dependencies": [1]},
    {"id": 3, "slug": "auth-middleware", "dependencies": [1]},
    {"id": 4, "slug": "integration-tests", "dependencies": [1, 2, 3]}
  ]
}
```

In this example: swarm 1 launches immediately; swarms 2 and 3 launch in parallel once swarm 1 completes; swarm 4 launches only after all three predecessors finish.

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

7. **Write checkpoint after each swarm completes**: Checkpoints enable crash recovery if the meta-lead process dies mid-run.
   ```bash
   # Write checkpoint after each swarm completes
   echo "{\"lastCompletedSwarm\": ${i}, \"completedSwarms\": [${COMPLETED_LIST}], \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$STATE_DIR/checkpoint.json"
   ```

   **Resuming from a checkpoint**: If the meta-lead crashes, a new session can pick up from the last checkpoint:
   ```bash
   # On resume, read checkpoint to skip already-completed swarms
   if [ -f "$STATE_DIR/checkpoint.json" ]; then
     COMPLETED=$(jq -r '.completedSwarms[]' "$STATE_DIR/checkpoint.json")
     echo "Resuming from checkpoint — already completed swarms: $COMPLETED"
     # Skip monitoring for completed swarms, continue polling the rest
   fi
   ```
   The checkpoint file is updated atomically (write to temp file, then `mv`) to avoid corruption from partial writes.

---

### Phase 3.5: Streaming Merge (merge-as-you-go)

While Phase 3 monitors swarm progress, the streaming merge watcher (launched in Phase 2) runs concurrently:

1. **How it works**: The `streaming-merge.sh` script polls swarm status files. When any swarm reaches `phase: "done"`, it immediately:
   - Rebases the swarm branch onto the latest base branch
   - Pushes and creates a PR
   - Squash-merges the PR
   - Updates the base branch for subsequent merges

2. **Dependency awareness**: If swarm B depends on swarm A (per the manifest), B's merge is deferred until A is merged first.

3. **Conflict handling**: If a rebase produces conflicts, the swarm is marked as `"conflict"` in the results file and skipped. Conflicted swarms are left for Phase 4 to handle manually.

4. **Progress tracking**: Merge results are written to `$STATE_DIR/merge-results.json`:
   ```json
   {
     "runId": "{run-id}",
     "baseBranch": "main",
     "swarmCount": 4,
     "startedAt": "ISO timestamp",
     "completedAt": null,
     "swarms": {
       "1": {"status": "merged", "prUrl": "https://...", "error": null, "mergedAt": "ISO timestamp"},
       "3": {"status": "merged", "prUrl": "https://...", "error": null, "mergedAt": "ISO timestamp"},
       "2": {"status": "conflict", "prUrl": null, "error": "Rebase conflict", "mergedAt": "ISO timestamp"}
     }
   }
   ```

5. **Monitor integration**: During Phase 3 polling, also check merge progress:
   ```bash
   if [ -f "$STATE_DIR/merge-results.json" ]; then
     MERGED=$(jq '[.swarms[] | select(.status == "merged")] | length' "$STATE_DIR/merge-results.json")
     echo "Streaming merge: $MERGED swarms merged so far"
   fi
   ```

This overlapping of Phase 3 and Phase 4 significantly reduces total pipeline time — merges happen as work completes rather than waiting for the slowest swarm.

---

### Phase 4: Finalize Remaining Merges

By this point, the streaming merge watcher (Phase 3.5) has already merged most completed swarms. Phase 4 handles any remaining swarms that weren't merged during streaming — typically those with conflicts or late finishers.

1. **Check streaming merge results**:
   ```bash
   ALREADY_MERGED=$(jq -r '.swarms | to_entries[] | select(.value.status == "merged") | .key' "$STATE_DIR/merge-results.json" 2>/dev/null || echo "")
   ```

2. **Stop the streaming merge watcher**:
   ```bash
   STREAMING_PID=$(cat "$STATE_DIR/streaming-merge.pid" 2>/dev/null)
   if [ -n "$STREAMING_PID" ]; then
     kill "$STREAMING_PID" 2>/dev/null || true
   fi
   ```

3. **For each completed swarm** (where `status.phase === "done"`), in order:
   > Skip swarms already merged by streaming (check `$ALREADY_MERGED`)

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

4. **Handle merge conflicts**:
   - If rebase fails: leave PR open, log conflict, continue with next swarm
   - Report all conflicts at the end
   - Suggest manual resolution steps

5. **Track merge results**: Update `$STATE_DIR/merge-results.json` (same file used by streaming merge) with results for any newly merged swarms. The file uses per-swarm entries under the `"swarms"` key — see Phase 3.5 step 4 for the format.

---

### Phase 5: Cleanup

1. **Kill tmux session**:
   ```bash
   tmux kill-session -t "swarm-${RUN_ID}" 2>/dev/null || true
   ```

2. **Stop streaming merge watcher** (if still running):
   ```bash
   STREAMING_PID=$(cat "$STATE_DIR/streaming-merge.pid" 2>/dev/null)
   if [ -n "$STREAMING_PID" ] && kill -0 "$STREAMING_PID" 2>/dev/null; then
     kill "$STREAMING_PID" 2>/dev/null || true
   fi
   ```

3. **Collect artifacts and clean up worktrees**:
   ```bash
   for i in $(seq 1 $SWARMS); do
     WORKTREE=".claude/worktrees/swarm-${RUN_ID}-${i}"
     if [ -d "$WORKTREE" ]; then
       WORKTREE_NAME=$(basename "$WORKTREE")
       ARTIFACTS_DIR="${HOME}/.claude/artifacts/${WORKTREE_NAME}"
       mkdir -p "$ARTIFACTS_DIR"
       # Collect coverage/test artifacts
       for d in coverage .nyc_output htmlcov; do
         [ -d "${WORKTREE}/${d}" ] && cp -r "${WORKTREE}/${d}" "${ARTIFACTS_DIR}/" 2>/dev/null || true
       done
       for f in test-results.xml junit.xml test-report.html; do
         [ -f "${WORKTREE}/${f}" ] && cp "${WORKTREE}/${f}" "${ARTIFACTS_DIR}/" 2>/dev/null || true
       done
       # Clean heavy directories and .env files
       for d in node_modules .next dist build target __pycache__ .pytest_cache .tox .venv venv; do
         rm -rf "${WORKTREE}/${d}" 2>/dev/null || true
       done
       for envfile in .env .env.local .env.development.local .env.test.local .env.production.local; do
         rm -f "${WORKTREE}/${envfile}" 2>/dev/null || true
       done
     fi
   done
   ```

4. **Remove worktrees**:
   ```bash
   for i in $(seq 1 $SWARMS); do
     WORKTREE=".claude/worktrees/swarm-${RUN_ID}-${i}"
     git worktree remove "$WORKTREE" --force 2>/dev/null || true
   done
   git worktree prune
   ```

5. **Clean up branches** for merged swarms:
   ```bash
   for i in ${MERGED_SWARMS}; do
     BRANCH="swarm/${RUN_ID}/${i}-${SLUG}"
     git branch -D "$BRANCH" 2>/dev/null || true
   done
   ```

6. **Stop gateway** if no other runs are active:
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

7. **Write final summary** to `$STATE_DIR/result.json`:
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

8. **Report to user**: Show final summary with:
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
| Dependency failure | Prerequisite swarm fails/errors | All transitive dependents marked as `blocked`, reported to user |
| DAG cycle detected | `dag-scheduler.sh` startup validation | Abort run immediately — manifest must be corrected |
| Retry with backoff | Git push or PR operation fails transiently | `streaming-merge.sh` retries with exponential backoff (1s, 2s, 4s, 8s, 16s), max 5 attempts |
| Checkpoint resume | Meta-lead process crashes mid-run | Read `$STATE_DIR/checkpoint.json` to identify completed swarms, skip them, resume monitoring the rest |

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CLAUDE_PLUGIN_ROOT` | Plugin installation root directory |
| `STATE_DIR` | Run state directory (`~/.claude/multi-swarm/state/{run-id}`) |
| `RUN_ID` | Current run identifier (timestamp + random hex) |
| `BASE_BRANCH` | Base branch for worktrees and PR targets |
| `SWARMS` | Number of parallel swarms |
| `TEAM_SIZE` | Number of teammates per swarm |
| `USE_DAG_SCHEDULER` | Set to `1` to force DAG scheduling mode even without explicit dependencies |
| `SWARM_ID` | Current swarm's numeric ID (set within swarm context) |
| `WORKTREE_PATH` | Path to the current swarm's worktree |
| `SOURCE_PROJECT` | Original project root directory |
| `LOG_LEVEL` | Logging verbosity: `debug`, `info`, `warn`, or `error` |
| `MAX_RETRIES` | Maximum retry attempts for failed swarms |
| `POLL_INTERVAL` | Status polling interval in seconds |
| `MAX_RUNTIME` | Maximum swarm runtime in minutes before forced termination |

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

# Tasks with dependencies (auto-uses DAG scheduler)
/multi-swarm "Build auth system with API, UI, and integration tests"
# Decomposes into:
#   Swarm 1: auth-api (no deps) — launches immediately
#   Swarm 2: auth-ui (depends on 1) — waits for API
#   Swarm 3: auth-middleware (depends on 1) — waits for API, runs parallel with 2
#   Swarm 4: integration-tests (depends on 1, 2, 3) — waits for all others

# Force DAG scheduler even without explicit dependencies
USE_DAG_SCHEDULER=1 /multi-swarm "Refactor database layer" --swarms 4
```
