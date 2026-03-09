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
- **CRITICAL**: Stop-everything emergencies (e.g., base branch broken, security vulnerability discovered, data corruption). All swarms must halt and respond.
- **BLOCKER**: Warn about conflicts or blocking issues (e.g., file conflicts, failing tests that affect others). Treat BLOCKER messages as HIGH PRIORITY — read and respond immediately.
- **REQUEST**: Ask a specific swarm for information or action. Always include what you need and why.
- **DISCOVERY**: Share findings with other swarms (e.g., found reusable code, discovered a pattern). Use liberally — shared knowledge prevents duplicate work.
- **BROADCAST**: Announcements to all swarms (e.g., status updates, merge notifications). Keep broadcasts rare and important.

### IPC Priority Rules

Messages are prioritized in strict order: **CRITICAL > BLOCKER > REQUEST > DISCOVERY > BROADCAST**. Higher-priority messages always preempt lower-priority work.

| Priority | Max Response Time | Required Action | Escalation Path |
|---|---|---|---|
| **CRITICAL** | Immediate (< 30s) | Stop current work, acknowledge, and act | Auto-escalates to meta-lead after 60s, then to user after 120s |
| **BLOCKER** | < 2 minutes | Pause at next safe point, acknowledge, and resolve | Escalates to swarm lead after 5 min, meta-lead after 10 min |
| **REQUEST** | < 5 minutes | Handle at next phase transition | Escalates to swarm lead after 15 min if no acknowledgment |
| **DISCOVERY** | Best effort | Acknowledge if it affects your approach | No escalation — informational |
| **BROADCAST** | No response required | Read and note; no acknowledgment needed | No escalation — informational |

**Rules**:
- When a CRITICAL or BLOCKER message arrives mid-task, finish the current atomic operation (e.g., complete a file write), then handle the message before continuing
- Never defer a BLOCKER message to handle a DISCOVERY or BROADCAST
- If you receive multiple messages at the same priority level, process them in chronological order (oldest first)
- A swarm may upgrade a message priority if the original priority was insufficient (e.g., a REQUEST that becomes a BLOCKER when a deadline is missed)

### When to Send Messages
- Send a CRITICAL only for stop-everything emergencies — base branch broken, security issue, or data loss risk
- Send a BLOCKER immediately when you detect a conflict or issue affecting another swarm
- Send a REQUEST when you need information or coordination from a specific swarm
- Send a DISCOVERY when you find something that other swarms might benefit from
- Send a BROADCAST for major milestones (e.g., "finished core implementation, ready for integration")
- Do NOT flood the bus — only send messages that are actionable

### When to Check Messages
- Check your IPC inbox at every phase transition
- Check your IPC inbox before editing any shared or potentially contested file
- Act on CRITICAL messages immediately — drop everything
- Act on BLOCKER messages before continuing your current work
- Acknowledge DISCOVERY messages that affect your approach

### Message Etiquette
- Keep messages concise and actionable — one topic per message
- Include context: what you found, why it matters, what action is needed
- For CRITICAL messages: include the severity, affected scope, and required immediate action
- For BLOCKER messages: include the file path and nature of the conflict
- For REQUEST messages: include a clear question and expected response format
- Never ignore BLOCKER or CRITICAL messages — they indicate issues that can waste time or break the run

### Message Rate Limiting

To prevent message bus flooding and ensure signal quality:

- **Per-swarm limit**: Maximum 10 messages per minute per swarm. If you hit the limit, batch remaining messages.
- **Same-topic cooldown**: Do not send more than 1 message on the same topic within 2 minutes. If the situation has changed, update your previous message rather than sending a new one.
- **Exponential backoff**: If a REQUEST receives no response, retry with increasing delays: 2 min → 4 min → 8 min → escalate to swarm lead. Do not spam repeated requests.
- **BROADCAST throttle**: Maximum 3 BROADCAST messages per swarm per run. Reserve broadcasts for genuinely significant milestones.
- **CRITICAL exempt**: CRITICAL messages are exempt from rate limits — send them whenever needed, but misuse of CRITICAL priority is a protocol violation.

### Deadlock Prevention

Deadlocks occur when swarms form circular wait chains (swarm A waits on swarm B, which waits on swarm A). These must be detected and broken quickly.

#### Circular Wait Detection

- Each swarm tracks its current wait target (which swarm it's waiting on) in `status.json`
- The orchestrator periodically scans all `status.json` files to detect cycles in the wait graph
- A cycle is confirmed when: `swarm A → waits on B → waits on C → waits on A`

#### Prevention Strategies

1. **Timeout-based deadlock breaking**: If a swarm has been waiting for a response longer than 10 minutes, it assumes deadlock and initiates the recovery protocol
2. **Hierarchical resource ordering**: When two swarms need to coordinate on shared resources, the swarm with the **lower ID** gets priority. Swarm 1 always wins over swarm 2, swarm 2 over swarm 3, etc. This prevents circular waits by imposing a total order.
3. **Non-blocking requests**: Prefer non-blocking REQUESTs that allow work to continue on other subtasks while waiting. Only block when the response is truly required to proceed.
4. **Lock timeout**: Any lock held on a shared resource (e.g., flock on merge lock) must have a timeout (default: 60s). Never hold a lock indefinitely.

#### Deadlock Recovery

When a deadlock is detected or a timeout fires:
1. The swarm with the **higher ID** in the cycle backs off — it releases any locks, abandons the current wait, and retries after a 30-second delay
2. The backed-off swarm sends a BLOCKER message explaining the deadlock and its backoff
3. If the deadlock persists after 3 backoff cycles, escalate to the swarm lead for manual resolution
4. The swarm lead may reassign tasks, reorder dependencies, or break the cycle by completing one swarm's dependency directly

### Conflict Escalation Protocol

When conflicts arise between swarms, resolve them at the lowest possible level before escalating:

```
Level 1: Local Resolution (< 5 min)
  └── Swarms involved communicate directly via REQUEST messages
  └── Apply hierarchical ordering (lower swarm ID has priority)
  └── If resolved: send DISCOVERY summarizing the resolution

Level 2: Swarm Lead (5-15 min)
  └── If local resolution fails, escalate to your swarm lead
  └── Swarm lead coordinates with the other swarm's lead
  └── Swarm lead may reassign files, adjust scopes, or serialize work

Level 3: Meta-Lead / Orchestrator (15-30 min)
  └── If swarm leads cannot resolve, escalate to meta-lead
  └── Meta-lead has authority to reorder swarms, merge scopes, or pause swarms
  └── Meta-lead decision is final for the current run

Level 4: User Intervention (> 30 min)
  └── If meta-lead cannot resolve (e.g., contradictory requirements)
  └── Pause affected swarms and present the conflict to the user
  └── User provides resolution; swarms resume with updated instructions
```

**Escalation rules**:
- Always attempt the current level before escalating — do not skip levels
- Include full context at each escalation: what was tried, why it failed, what options remain
- Time limits are guidelines — escalate sooner if the conflict is clearly beyond the current level's authority

## Resource Discipline
- Do not install new dependencies without checking if they're already available
- Do not create files outside the project's conventional directories
- Clean up any temporary files before marking work as complete
- Respect the project's existing code style and conventions
