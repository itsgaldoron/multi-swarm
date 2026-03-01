# Multi-Swarm Coordination Rules

All agents participating in a multi-swarm run MUST follow these rules:

## Git Discipline
- Always pull the latest changes before starting work
- Commit frequently with the `[swarm-{N}]` prefix in commit messages (e.g., `[swarm-1] Add login page`)
- Never force-push or rebase without explicit instruction
- Check `git status` before editing any file to avoid conflicts with uncommitted changes

## Scope Discipline
- Only modify files listed in your assigned scope (`fileScope` in your task)
- Never modify files listed in `noParallelEdit` — these are shared across swarms
- If you need to change a shared file, message your swarm lead and wait for coordination
- Keep changes minimal and focused on your assigned subtask

## Quality Discipline
- Run the project's test command before marking any task as complete
- Run the project's lint command if available
- Fix any errors you introduce — do not leave broken code for others
- Write tests for new functionality when a test framework is available

## Communication Discipline
- Write `status.json` updates at every phase transition (analyzing → planning → working → testing → done)
- If blocked, message your team lead immediately with specific details
- When idle, review recent commits from other teammates for bugs and style issues
- Do not send unnecessary messages — be concise and actionable

## Resource Discipline
- Do not install new dependencies without checking if they're already available
- Do not create files outside the project's conventional directories
- Clean up any temporary files before marking work as complete
- Respect the project's existing code style and conventions
