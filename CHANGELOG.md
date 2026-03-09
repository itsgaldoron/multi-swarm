# Changelog

## [1.3.0] - 2026-03-01

### Added
- **Shared library** (`lib/common.sh`) — common functions for logging, retry-with-backoff, dependency checking, and phase colors, used across all scripts
- **Checkpoint/resume** — crashed meta-lead can resume from last successful merge checkpoint (`checkpoint.json`)
- **Retry with exponential backoff** — git push, PR creation, and merge operations retry with backoff (1s→2s→4s→8s→16s, max 5 retries)
- **Environment variable reference** in SKILL.md documenting all script variables

### Changed
- All scripts hardened with `set -euo pipefail`, proper quoting, and error handling
- Agent prompts upgraded with structured status updates, error recovery steps, and role-specific improvements
- SKILL.md Phase 1 decomposition guidance expanded with better examples
- SKILL.md Phase 3 now includes checkpoint/resume instructions
- Error recovery table expanded with retry-with-backoff and checkpoint resume rows
- IPC scripts hardened with atomic flock patterns and proper signal handling
- Quality gate scripts standardized with shared library functions
- Dashboard and monitor scripts fixed for arithmetic edge cases and temp file cleanup

### Fixed
- TOCTOU race conditions in lock/PID file handling (ipc-watcher.sh, streaming-merge.sh)
- Division-by-zero guards in monitor.sh and dashboard.sh
- Unquoted variables in arithmetic contexts (dashboard.sh, cost-tracker.sh)
- Temp file leaks in dashboard.sh render_heatmap()
- Unchecked git checkout exit codes in streaming-merge.sh
- Empty array edge case in dag-scheduler.sh get_merge_order
- Redundant jq calls in quality-gate.sh (parse once, reuse)
- Hardcoded sparkline array sizes in dashboard.sh
- Fragile filename parsing in ipc.sh
- Missing numeric input validation in cost-tracker.sh

## [1.2.0] - 2026-03-01

### Added
- **Streaming merge pipeline** — swarms merge as they complete instead of waiting for all to finish; Phase 3 and Phase 4 now overlap (`streaming-merge.sh`)
- **Model router** — all agents use Opus for maximum performance; `model-router.sh` provides consistent model mapping (`model-router.sh`)
- **Cost tracking** — per-swarm token usage and cost estimation (`cost-tracker.sh`)
- **Inter-swarm IPC** — file-based message bus for cross-swarm communication with DISCOVERY, BLOCKER, BROADCAST, and REQUEST message types (`ipc.sh`, `ipc-watcher.sh`)
- **DAG-based dependency scheduler** — swarms can declare dependencies; dependent swarms launch only when prerequisites complete, with dynamic rebalancing when swarms finish early (`dag-scheduler.sh`)
- **Scheduler agent** — new agent type that monitors the DAG and triggers launches (`scheduler.md`)
- **Parallel quality gates** — tests, lint, and type-checking run concurrently instead of sequentially (`parallel-quality.sh`)
- **Quality scorecards** — per-swarm quality reports with pass/fail breakdown (`quality-report.sh`)
- **Rich monitoring dashboard** — ANSI TUI with progress bars, color-coded status, agent activity, and cost display (`dashboard.sh`)
- **Metrics collector** — aggregates performance data: tokens, time per phase, commits per minute (`metrics.sh`)
- **Monitor watch mode** — `monitor.sh --watch` for continuous auto-refresh with keyboard controls (q=quit, r=refresh)
- **Monitor background mode** — `monitor.sh --background` runs as a daemon logging snapshots to file
- **Pre-commit quality hook** — validates changes before each commit, not just on task completion
- **Coverage threshold enforcement** in quality gates
- **Opus model across all agents** — every agent uses Opus for best quality, no cost-based downgrades
- **IPC protocol rules** in swarm-etiquette.md
- **IPC context injection** — subagents are made aware of the IPC system on start

### Changed
- `monitor.sh` rewritten from 100-line status printer to 600+ line rich dashboard with metrics integration
- `quality-gate.sh` expanded from basic test/lint to parallel multi-check system with IDE diagnostics support
- `gateway-setup.sh` simplified to single Opus model routing through LiteLLM
- `swarm.sh` updated with DAG-aware launch mode
- `SKILL.md` updated with streaming merge protocol and DAG scheduling documentation
- `merge-coordinator.md` updated with streaming merge mode
- `hooks.json` expanded with new hook points for pre-commit validation and parallel quality
- `inject-context.sh` now includes IPC awareness in subagent context

## [1.1.0] - 2026-03-01

### Fixed
- Remove invalid `WorktreeCreate` and `WorktreeRemove` hook events (not supported by Claude Code)
- Fix broken `$0` PLUGIN_ROOT pattern in SKILL.md (markdown is not an executed script)
- Add `SendMessage` and `TaskUpdate` to code-reviewer and researcher agent tools
- Remove unsupported `settings.json` keys (`env`, `permissions`, `teammateMode` are silently ignored)
- Fix merge-coordinator template reference with broken relative path
- Fix swarm.sh monitor help message relative path
- Inline worktree setup/teardown logic into swarm.sh (replaces non-functional hooks)

### Changed
- Inline PR body format in merge-coordinator (was referencing dead template)

### Added
- Component paths in plugin.json (`agents`, `skills`, `hooks`)
- `.gitignore` for runtime state and generated files
- `LICENSE` (MIT)
- This changelog

### Removed
- `settings.json` (only `agent` key is supported; critical env vars moved to launch scripts)
- `templates/` directory and all 3 template files (dead code — scripts generate inline)

## [1.0.0] - 2026-03-01

### Added
- Initial release
- Multi-swarm parallel orchestration with tmux
- Git worktree isolation per swarm
- Agent team coordination (swarm-lead, feature-builder, code-reviewer, researcher, test-writer, merge-coordinator)
- LiteLLM OAuth token gateway with round-robin rotation
- Quality gate hook on task completion
- Idle teammate reassignment hook
- File-based IPC for swarm status tracking
- Sequential PR creation and merge with conflict handling
