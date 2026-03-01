#!/usr/bin/env bash
# Inject Context — SubagentStart Hook
# Injects multi-swarm coordination context into every subagent

# This hook is called when a subagent starts. It outputs context that gets
# injected into the subagent's system prompt.

cat << 'CONTEXT'
## Multi-Swarm Context

You are part of a multi-swarm parallel execution system. Multiple Claude Code
sessions are working on different parts of the same project simultaneously.

### Rules
- Commit frequently with descriptive messages
- Run tests before finishing any task
- Keep changes minimal and focused on your assigned scope
- Do not modify files outside your assigned scope
- If you encounter a file that seems to be modified by another swarm, do not touch it
- Check git status before editing any file
- If blocked, message your team lead immediately

### Quality
- Always run the project's test command before marking work complete
- Fix any test failures you introduce
- Follow existing code patterns and conventions
- Write clean, readable code with no debugging artifacts
CONTEXT
