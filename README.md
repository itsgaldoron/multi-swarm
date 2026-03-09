# Multi-Swarm

Parallel orchestration plugin for Claude Code. Runs N independent Claude Code sessions — each with its own git worktree and agent team — coordinated by a meta-lead, with automatic token rotation through a LiteLLM gateway. Includes a shared function library (`lib/common.sh`), checkpoint/resume for crash recovery, and retry-with-backoff for resilient git operations.

```
Meta-Lead (your Claude Code session)
│
├─ LiteLLM Gateway (localhost:4000, round-robin across OAuth tokens)
│
├─ DAG Scheduler (dependency-aware launch ordering)
│
├─ Swarm 1 (tmux window + git worktree + agent team)
│   ├─ feature-builder  (opus)
│   ├─ test-writer       (opus)
│   ├─ code-reviewer     (opus)
│   └─ researcher        (opus)
│
├─ Swarm 2 (tmux window + git worktree + agent team)
│   └─ ...
│
├─ Streaming Merge (merges completed swarms while others still run)
│
├─ IPC Message Bus (cross-swarm DISCOVERY / BLOCKER / BROADCAST / REQUEST)
│
└─ Dashboard (real-time TUI with progress bars, cost tracking, metrics)
```

**Example**: N swarms x M teammates = dozens of concurrent Opus agents, all tokens active via gateway.

## Quick Install

```bash
claude plugin marketplace add https://github.com/itsgaldoron/multi-swarm
claude plugin install multi-swarm@multi-swarm-marketplace
```

Then open Claude Code in any project and type `/multi-swarm "your task"`.

---

## Prerequisites

- **Claude Code** >= 2.1.x with agent teams support
- **tmux** — `brew install tmux`
- **jq** — `brew install jq`
- **LiteLLM** — `pipx install 'litellm[proxy]' --python python3.13`
- **gh CLI** — `brew install gh` (for PR creation/merge)
- At least one Anthropic OAuth token

---

## Installation

### Step 1: Add the marketplace and install

```bash
# From GitHub
claude plugin marketplace add https://github.com/itsgaldoron/multi-swarm
claude plugin install multi-swarm@multi-swarm-marketplace

# Or from a local clone
claude plugin marketplace add /path/to/multi-swarm
claude plugin install multi-swarm@multi-swarm-marketplace
```

### Step 2: Add your token

The only manual step — provide at least one Anthropic OAuth token (`sk-ant-oat01-*` format):

```bash
mkdir -p ~/.claude/multi-swarm
echo '["sk-ant-oat01-YOUR-TOKEN"]' > ~/.claude/multi-swarm/tokens.json
chmod 600 ~/.claude/multi-swarm/tokens.json
```

A single token works fine — all swarms share it via the gateway. Add more tokens for load balancing at higher parallelism.

> **Config is automatic.** The plugin creates `~/.claude/multi-swarm/config.json` with sensible defaults on first run. To customize, see [Configuration](#per-project-configuration) below.

<details>
<summary>Default config (auto-generated)</summary>

```json
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
```

</details>

### Step 3: Verify

Open Claude Code in any project:

```bash
cd ~/my-project
claude
```

Type `/multi-swarm` — if the skill is recognized, the plugin is installed correctly.

---

## Usage

### Basic

```
/multi-swarm "Add user authentication with login, signup, and password reset"
```

The meta-lead will:
1. Analyze your codebase and decompose the task into independent subtasks
2. Present the decomposition for your approval
3. Start the LiteLLM gateway (if not running)
4. Launch N tmux windows, each with a git worktree and Claude Code session
5. Monitor progress until all swarms complete
6. Create and merge PRs sequentially

### With options

```
# Control parallelism
/multi-swarm "Refactor the API layer" --swarms 6 --team-size 4

# Preview without launching
/multi-swarm "Add dark mode" --dry-run

# Custom base branch
/multi-swarm "Fix lint errors" --base-branch develop --swarms 8 --team-size 2
```

### Monitoring

While swarms are running, use the monitor or dashboard:

```bash
# One-shot status
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh <run-id>

# Live dashboard (auto-refreshes every 5s, q=quit, r=refresh)
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh <run-id> --watch

# Custom refresh interval
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh <run-id> --watch -i 10

# Background monitoring (logs snapshots to file)
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh <run-id> --background
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh --status
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh --stop

# Full TUI dashboard with cost breakdown
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/dashboard.sh <run-id>
```

Or attach to the tmux session to watch individual swarms:

```bash
tmux attach -t swarm-20260301-153045-a1b2
# Ctrl+B, N to switch between swarm windows
```

### Gateway management

```bash
# Start the gateway manually
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/gateway-setup.sh

# Health check
curl -H "Authorization: Bearer ms-gateway-key" http://127.0.0.1:4000/health

# Stop the gateway
kill $(cat ~/.claude/multi-swarm/gateway.pid)
```

---

## Per-Project Configuration

Override global defaults by creating `.multi-swarm/config.json` in your project root:

```json
{
  "defaults": {
    "swarms": 6,
    "teamSize": 4
  },
  "project": {
    "packageManager": "pnpm",
    "testCommand": "pnpm test",
    "lintCommand": "pnpm lint"
  },
  "constraints": {
    "noParallelEdit": [
      "lib/constants.ts",
      "prisma/schema.prisma",
      "package.json"
    ]
  }
}
```

You can also add project-specific worktree setup/teardown scripts:

```
.multi-swarm/
├── config.json          # Project overrides
├── setup.sh             # Runs after dependency install in each worktree
├── teardown.sh          # Runs before worktree removal
└── task-hints.md        # Hints for task decomposition (injected into meta-lead)
```

**`setup.sh`** receives the worktree path as `$1`:

```bash
#!/bin/bash
# Example: seed the dev database, generate types
cd "$1"
pnpm db:generate
pnpm db:seed
```

**`teardown.sh`** receives the worktree path as `$1`:

```bash
#!/bin/bash
# Example: stop any dev servers
lsof -ti:${PORT} | xargs kill 2>/dev/null || true
```

---

## Plugin Structure

```
multi-swarm/
├── .claude-plugin/
│   └── plugin.json                    # Plugin manifest (agents, skills, hooks paths)
├── README.md                          # This file
│
├── agents/                            # Agent definitions (7 agents)
│   ├── swarm-lead.md                  # Swarm coordinator (opus)
│   ├── feature-builder.md             # Implementation specialist (opus, worktree)
│   ├── code-reviewer.md               # Review specialist (opus)
│   ├── test-writer.md                 # Test specialist (opus, worktree)
│   ├── researcher.md                  # Research specialist (opus)
│   ├── merge-coordinator.md           # PR merge specialist (opus, streaming mode)
│   └── scheduler.md                   # DAG scheduler agent (opus)
│
├── skills/multi-swarm/
│   ├── SKILL.md                       # /multi-swarm entry point
│   └── scripts/
│       ├── lib/
│       │   └── common.sh              # Shared functions (logging, retry, require_command)
│       ├── gateway-setup.sh           # LiteLLM config gen + start
│       ├── swarm.sh                   # tmux orchestrator (DAG-aware launch)
│       ├── worktree-setup.sh          # Standalone worktree setup (reference)
│       ├── worktree-teardown.sh       # Standalone worktree teardown (reference)
│       ├── quality-gate.sh            # Test/lint/typecheck gate (TaskCompleted hook)
│       ├── parallel-quality.sh        # Concurrent test + lint + typecheck runner
│       ├── quality-report.sh          # Per-swarm quality scorecards
│       ├── idle-reassign.sh           # Redirect idle agents (TeammateIdle hook)
│       ├── inject-context.sh          # Swarm rules + IPC awareness (SubagentStart hook)
│       ├── monitor.sh                 # Rich status dashboard (--watch, --background)
│       ├── dashboard.sh               # Full TUI dashboard with ANSI graphics
│       ├── metrics.sh                 # Performance and cost metrics collector
│       ├── cost-tracker.sh            # Token usage and cost estimation
│       ├── model-router.sh            # Agent role → model mapping (all Opus)
│       ├── dag-scheduler.sh           # Dependency-aware swarm scheduling
│       ├── streaming-merge.sh         # Merge-as-you-go pipeline
│       ├── ipc.sh                     # Inter-swarm message bus
│       └── ipc-watcher.sh             # IPC daemon for message delivery
│
├── hooks/hooks.json                   # Lifecycle hook wiring
└── rules/swarm-etiquette.md           # Coordination rules + IPC protocol
```

### Global files (not in plugin, stored at `~/.claude/multi-swarm/`)

```
~/.claude/multi-swarm/
├── config.json                        # Global defaults
├── tokens.json                        # OAuth tokens (chmod 600)
└── state/{run-id}/                    # Runtime state (auto-created per run)
    ├── manifest.json                  # Task decomposition
    └── swarms/swarm-{N}/
        ├── status.json                # Swarm progress
        ├── pid.txt                    # tmux pane PID
        └── prompt.md                  # Rendered swarm prompt
```

---

## How It Works

### Worktree Setup

Each swarm gets an isolated git worktree. The setup script auto-detects your project:

| Lock file | Package manager | Install command |
|-----------|----------------|-----------------|
| `pnpm-lock.yaml` | pnpm | `pnpm install --frozen-lockfile` |
| `yarn.lock` | yarn | `yarn install --frozen-lockfile` |
| `bun.lockb` | bun | `bun install --frozen-lockfile` |
| `package-lock.json` | npm | `npm ci` |
| `Cargo.toml` | cargo | `cargo build` |
| `go.mod` | go | `go mod download` |
| `requirements.txt` | pip | `pip install -r requirements.txt` |
| `pyproject.toml` | uv/poetry/pip | auto-detected |
| `Gemfile` | bundler | `bundle install` |

It also copies `.env` files from the source project and assigns a deterministic port based on worktree name.

### Quality Gate

The `TaskCompleted` hook runs automatically when any agent marks a task as done:

1. Runs tests, lint, and type-checking **in parallel** via `parallel-quality.sh`
2. Enforces coverage thresholds (if configured)
3. Validates pre-commit changes
4. Generates per-swarm quality scorecards via `quality-report.sh`
5. **Blocks completion if anything fails** — the agent must fix the issues first

### Model Strategy

All agents use **Opus** for maximum performance and quality. Every agent — from researchers to feature-builders — gets the most capable model available. The `cost-tracker.sh` script tracks token usage and cost per run.

### Token Rotation

The LiteLLM gateway distributes requests across your tokens. A single token is all you need to get started — all swarms share it through the gateway. Adding more tokens enables load balancing for higher throughput:

- **Single token**: Works out of the box — all swarms route through it
- **Multiple tokens**: `usage-based-routing-v2` sends requests to the least-loaded key
- **Circuit breaking**: Rate-limited keys cool down for 60s automatically
- **Failover**: If one key is down, requests route to the next
- **All Opus**: Every agent uses the Opus endpoint for best results

### Inter-Swarm Communication

Swarms can communicate via a file-based IPC message bus:

| Message Type | Purpose |
|-------------|---------|
| `DISCOVERY` | Share findings (e.g., "found existing auth helper at src/utils/auth.ts") |
| `BLOCKER` | Warn about conflicts (e.g., "I need to modify the shared config") |
| `BROADCAST` | Announcements (e.g., "database schema changed") |
| `REQUEST` | Ask another swarm for information |

```bash
# Send a message (from within a swarm)
bash scripts/ipc.sh send --from 1 --type DISCOVERY --msg "Found existing auth helper"

# The ipc-watcher.sh daemon delivers messages to recipient swarms
```

### DAG-Based Scheduling

Swarms can declare dependencies in the manifest. The `dag-scheduler.sh` manages launch ordering:

```json
{
  "swarms": [
    { "id": 1, "slug": "database-schema", "dependencies": [] },
    { "id": 2, "slug": "api-endpoints", "dependencies": [1] },
    { "id": 3, "slug": "ui-components", "dependencies": [] },
    { "id": 4, "slug": "integration-tests", "dependencies": [2, 3] }
  ]
}
```

Swarms 1 and 3 launch immediately. Swarm 2 launches when 1 completes. Swarm 4 launches when both 2 and 3 complete. When a swarm finishes early, its resources are available for rebalancing.

### Shared Library

All scripts source `lib/common.sh` for shared functionality:

- **`log()` / `log_error()`** — consistent logging with timestamps and script name
- **`require_command()`** — dependency checking with actionable error messages
- **`retry_with_backoff()`** — exponential backoff for flaky operations (git push, PR creation, merge)
- **`phase_color()`** — ANSI color mapping for phase names in dashboard/monitor output

### Checkpoint / Resume

Crashed runs can be resumed from the last successful merge checkpoint. The streaming merge pipeline writes a `checkpoint.json` after each successful merge. If the meta-lead crashes mid-run, restarting the same run ID will pick up from the last checkpoint, skipping already-merged swarms.

### Retry with Backoff

Git push, PR creation, and merge operations now retry with exponential backoff: 1s, 2s, 4s, 8s, 16s (max 5 retries). This handles transient GitHub API errors and rate limiting without manual intervention. All retry logic is provided by `retry_with_backoff()` from `lib/common.sh`.

### Streaming Merge

Completed swarms merge immediately while others continue working (Phase 3 and Phase 4 overlap):

1. `streaming-merge.sh` watches for completed swarms
2. As each completes: rebase, push, create PR, squash merge
3. Pull latest base before next merge
4. Other swarms keep running in parallel
5. If conflict: leave PR open, continue with next swarm, report at the end

This eliminates the idle wait time between the last swarm completing and the first merge starting.

---

## Parallelism Budget

| Swarms | Team Size | Total Agents | Recommended Tokens |
|--------|-----------|--------------|-------------------|
| 2 | 2 | 7 | 1+ |
| 4 | 3 | 17 | 1+ |
| 6 | 4 | 31 | 3+ |
| N | M | N*(M+1)+1 | 1 minimum |

A single token works at any scale. More tokens improve throughput and reduce rate-limit pressure at higher parallelism.

**Recommended start**: 4 swarms, 3 teammates each. Scale up after validating.

**Cost estimate** (Opus $15/$75 per M tokens): All agents run on Opus for maximum performance. Track actual costs per run with `cost-tracker.sh` and the dashboard.

---

## Troubleshooting

### Gateway won't start

```bash
# Check logs
cat ~/.claude/multi-swarm/gateway.log

# Common fix: Python version issue
pipx uninstall litellm
pipx install 'litellm[proxy]' --python python3.13
```

### Swarm stuck or crashed

```bash
# Check tmux windows
tmux list-windows -t "swarm-<run-id>"

# Attach to specific swarm
tmux select-window -t "swarm-<run-id>:swarm-3"

# Check swarm status
cat ~/.claude/multi-swarm/state/<run-id>/swarms/swarm-3/status.json | jq .
```

### Worktree setup fails

Worktree setup runs inline during `swarm.sh` launch. Check the tmux monitor window for setup errors, or test the standalone script manually:

```bash
SOURCE_PROJECT=$(pwd) WORKTREE_PATH=/path/to/worktree \
  bash ~/.claude/plugins/cache/multi-swarm-marketplace/multi-swarm/1.2.0/skills/multi-swarm/scripts/worktree-setup.sh
```

### Run crashed mid-way

If the meta-lead or a swarm crashes during execution, you can resume from the last checkpoint:

```bash
# Re-run with the same run ID — it picks up from the last successful merge
/multi-swarm "Original task description" --resume <run-id>

# Check what was already merged
cat ~/.claude/multi-swarm/state/<run-id>/checkpoint.json | jq .
```

The checkpoint tracks which swarms have been successfully merged, so already-completed work is not repeated.

### Git push fails intermittently

Git push, PR creation, and merge operations now automatically retry with exponential backoff (1s → 2s → 4s → 8s → 16s, max 5 retries). If pushes still fail after retries:

```bash
# Check GitHub status
curl -s https://www.githubstatus.com/api/v2/status.json | jq .status

# Check gateway health
curl -H "Authorization: Bearer ms-gateway-key" http://127.0.0.1:4000/health
```

### Token rate limiting

The LiteLLM gateway handles rate limiting with automatic circuit breaking — rate-limited keys cool down for 60 seconds and requests reroute to available keys. If all keys are rate-limited:

```bash
# Check gateway logs for rate limit events
grep "rate_limit" ~/.claude/multi-swarm/gateway.log

# Add more tokens to spread the load
vim ~/.claude/multi-swarm/tokens.json
```

### Clean up after a failed run

```bash
# Remove all worktrees from a run
for wt in .claude/worktrees/swarm-<run-id>-*; do
  git worktree remove "$wt" --force 2>/dev/null
done
git worktree prune

# Kill tmux session
tmux kill-session -t "swarm-<run-id>"

# Remove state
rm -rf ~/.claude/multi-swarm/state/<run-id>
```

---

## License

MIT
