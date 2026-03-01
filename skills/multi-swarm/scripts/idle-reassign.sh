#!/usr/bin/env bash
# Idle Reassign — TeammateIdle Hook
# Checks for pending tasks and redirects idle teammates

# Check if there are pending tasks in the current team
TEAM_DIR="$HOME/.claude/tasks/"

# Find the team directory for this session
if [ -n "${CLAUDE_TEAM_NAME:-}" ]; then
    TASK_DIR="$HOME/.claude/tasks/${CLAUDE_TEAM_NAME}"
else
    # Fall back to looking for any active team
    TASK_DIR=$(find "$HOME/.claude/tasks/" -maxdepth 1 -type d | tail -1)
fi

if [ -z "$TASK_DIR" ] || [ ! -d "$TASK_DIR" ]; then
    exit 0  # No team context, allow idle
fi

# Count pending unblocked tasks
PENDING=0
for task_file in "$TASK_DIR"/*.json; do
    [ -f "$task_file" ] || continue
    STATUS=$(jq -r '.status // ""' "$task_file" 2>/dev/null)
    OWNER=$(jq -r '.owner // ""' "$task_file" 2>/dev/null)
    BLOCKED=$(jq -r '.blockedBy | length // 0' "$task_file" 2>/dev/null)
    if [ "$STATUS" = "pending" ] && [ -z "$OWNER" ] && [ "$BLOCKED" -eq 0 ] 2>/dev/null; then
        PENDING=$((PENDING + 1))
    fi
done

if [ "$PENDING" -gt 0 ]; then
    echo "There are $PENDING pending unblocked tasks. Claim the next available task using TaskList and TaskUpdate."
    exit 2  # Block idle with redirect message
fi

# No pending tasks — suggest review work
echo "No pending tasks. Review recent commits from other teammates for bugs, style issues, and potential improvements."
exit 2
