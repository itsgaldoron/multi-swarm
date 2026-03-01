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

## IPC Protocol

Inter-swarm communication uses a file-based message bus. All swarms in a run share an IPC directory.

### Message Types
- **DISCOVERY**: Share findings with other swarms (e.g., found reusable code, discovered a pattern). Use liberally — shared knowledge prevents duplicate work.
- **BLOCKER**: Warn about conflicts or blocking issues (e.g., file conflicts, failing tests that affect others). Treat BLOCKER messages as HIGH PRIORITY — read and respond immediately.
- **BROADCAST**: Announcements to all swarms (e.g., status updates, merge notifications). Keep broadcasts rare and important.
- **REQUEST**: Ask a specific swarm for information or action. Always include what you need and why.

### When to Send Messages
- Send a DISCOVERY when you find something that other swarms might benefit from
- Send a BLOCKER immediately when you detect a conflict or issue affecting another swarm
- Send a BROADCAST for major milestones (e.g., "finished core implementation, ready for integration")
- Send a REQUEST when you need information or coordination from a specific swarm
- Do NOT flood the bus — only send messages that are actionable

### When to Check Messages
- Check your IPC inbox at every phase transition
- Check your IPC inbox before editing any shared or potentially contested file
- Act on BLOCKER messages before continuing your current work
- Acknowledge DISCOVERY messages that affect your approach

### Message Etiquette
- Keep messages concise and actionable — one topic per message
- Include context: what you found, why it matters, what action is needed
- For BLOCKER messages: include the file path and nature of the conflict
- For REQUEST messages: include a clear question and expected response format
- Never ignore BLOCKER messages — they indicate potential conflicts that can waste time

## Resource Discipline
- Do not install new dependencies without checking if they're already available
- Do not create files outside the project's conventional directories
- Clean up any temporary files before marking work as complete
- Respect the project's existing code style and conventions
