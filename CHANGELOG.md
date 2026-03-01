# Changelog

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
