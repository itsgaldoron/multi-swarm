# Multi-Swarm

Parallel orchestration plugin for Claude Code. Runs N independent Claude Code sessions — each with its own git worktree and agent team — coordinated by a meta-lead, with automatic token rotation through a LiteLLM gateway.

```
Meta-Lead (your Claude Code session)
│
├─ LiteLLM Gateway (localhost:4000, round-robins your OAuth tokens)
│
├─ Swarm 1 (tmux window + git worktree + agent team)
│   ├─ feature-builder
│   ├─ test-writer
│   └─ code-reviewer
│
├─ Swarm 2 (tmux window + git worktree + agent team)
│   └─ ...
└─ Swarm N
```

**Example**: 6 swarms x 4 teammates = 31 concurrent Opus agents, all tokens active via gateway.

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

### Step 2: Set up global config and tokens

Create two files in `~/.claude/multi-swarm/`:

```bash
# Create config directory
mkdir -p ~/.claude/multi-swarm

# Create global config (edit defaults to your preference)
cat > ~/.claude/multi-swarm/config.json << 'EOF'
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
    "masterKey": "sk-swarm-master",
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
EOF

# Add your OAuth tokens (one per line in a JSON array)
cat > ~/.claude/multi-swarm/tokens.json << 'EOF'
[
  "sk-ant-oat01-your-first-token",
  "sk-ant-oat01-your-second-token"
]
EOF
chmod 600 ~/.claude/multi-swarm/tokens.json
```

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

While swarms are running, use the monitor script:

```bash
# From another terminal
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh

# With a specific run ID
bash ~/.claude/plugins/multi-swarm/skills/multi-swarm/scripts/monitor.sh 20260301-153045-a1b2
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
curl -H "Authorization: Bearer sk-swarm-master" http://127.0.0.1:4000/health

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
├── agents/                            # Agent definitions
│   ├── swarm-lead.md                  # Swarm coordinator (opus)
│   ├── feature-builder.md             # Implementation specialist (opus, worktree)
│   ├── code-reviewer.md               # Review specialist (opus)
│   ├── test-writer.md                 # Test specialist (opus, worktree)
│   ├── researcher.md                  # Research specialist (opus)
│   └── merge-coordinator.md           # PR merge specialist (opus)
│
├── skills/multi-swarm/
│   ├── SKILL.md                       # /multi-swarm entry point
│   └── scripts/
│       ├── gateway-setup.sh           # LiteLLM config gen + start
│       ├── swarm.sh                   # tmux orchestrator (includes worktree setup)
│       ├── worktree-setup.sh          # Standalone worktree setup (reference)
│       ├── worktree-teardown.sh       # Standalone worktree teardown (reference)
│       ├── quality-gate.sh            # Test/lint gate (TaskCompleted hook)
│       ├── idle-reassign.sh           # Redirect idle agents (TeammateIdle hook)
│       ├── inject-context.sh          # Swarm rules (SubagentStart hook)
│       └── monitor.sh                 # Status dashboard
│
├── hooks/hooks.json                   # Lifecycle hook wiring
└── rules/swarm-etiquette.md           # Coordination rules for all agents
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

1. Runs the project's test suite
2. Runs the linter (if detected)
3. Runs TypeScript type checking (if `tsconfig.json` exists)
4. **Blocks completion if anything fails** — the agent must fix the issues first

### Token Rotation

The LiteLLM gateway distributes requests across all your tokens:

- **Routing**: `usage-based-routing-v2` sends requests to the least-loaded key
- **Circuit breaking**: Rate-limited keys cool down for 60s automatically
- **Failover**: If one key is down, requests route to the next
- **Models**: Each token serves the Opus endpoint exclusively

### Merge Strategy

Completed swarms merge sequentially via squash PRs:

1. Rebase swarm branch onto latest base
2. Push and create PR
3. Squash merge and delete branch
4. Pull latest before next rebase
5. If conflict: skip, leave PR open, report at the end

---

## Parallelism Budget

| Swarms | Team Size | Total Agents | Tokens Needed |
|--------|-----------|--------------|---------------|
| 2 | 2 | 7 | 5+ |
| 4 | 3 | 17 | 15+ |
| 6 | 4 | 31 | 25+ |
| 8 | 3 | 33 | 29+ |

**Recommended start**: 4 swarms, 3 teammates each. Scale up after validating.

**Cost estimate** (Opus $15/$75 per M tokens): ~$50-200/hour depending on agent count. Prompt caching reduces input costs by 60-80%.

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
  bash ~/.claude/plugins/cache/multi-swarm-marketplace/multi-swarm/1.1.0/skills/multi-swarm/scripts/worktree-setup.sh
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
