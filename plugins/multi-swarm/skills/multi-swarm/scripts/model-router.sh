#!/usr/bin/env bash
# Multi-Swarm Model Router
# Maps agent roles to Claude models. All agents use Opus for maximum performance.
# Both sourceable (for functions) and executable (for CLI usage).
#
# Environment Variables: (none)

# --- Model constant ---
TIER_OPUS="claude-opus-4-6"

# --- Cost per 1M tokens (USD) ---
OPUS_INPUT_COST=15
OPUS_OUTPUT_COST=75

# Returns the tier name for a given agent role.
# All roles use opus for maximum quality and performance.
get_model_tier() {
    local role="${1:?Usage: get_model_tier <role>}"
    echo "opus"
}

# Returns the full model ID for a given agent role.
get_model_for_role() {
    local role="${1:?Usage: get_model_for_role <role>}"
    echo "$TIER_OPUS"
}

# Returns all unique model IDs needed for a given set of roles (space-separated).
get_all_required_models() {
    echo "$TIER_OPUS"
}

# --- CLI mode (only runs when executed, not when sourced) ---
_model_router_cli() {
    local ALL_ROLES="swarm-lead feature-builder merge-coordinator test-writer researcher code-reviewer scheduler"

    case "${1:-}" in
        --list)
            printf "%-22s %-8s %s\n" "ROLE" "TIER" "MODEL"
            printf "%-22s %-8s %s\n" "----" "----" "-----"
            for role in $ALL_ROLES; do
                printf "%-22s %-8s %s\n" "$role" "opus" "$TIER_OPUS"
            done
            ;;
        --tier)
            local role="${2:?Usage: model-router.sh --tier <role>}"
            echo "opus"
            ;;
        --costs)
            printf "%-8s %12s %12s\n" "TIER" "INPUT/1M" "OUTPUT/1M"
            printf "%-8s %12s %12s\n" "----" "--------" "---------"
            printf "%-8s %11s$ %11s$\n" "opus" "$OPUS_INPUT_COST" "$OPUS_OUTPUT_COST"
            ;;
        --help|-h|"")
            echo "Usage: model-router.sh <role> | --list | --tier <role> | --costs"
            echo ""
            echo "Maps agent roles to Claude models. All agents use Opus for maximum performance."
            echo ""
            echo "Arguments:"
            echo "  <role>          Print the model ID for the given agent role"
            echo "  --list          Print all role-to-model mappings"
            echo "  --tier <role>   Print just the tier name for a role"
            echo "  --costs         Print cost-per-1M-tokens"
            echo "  --help          Show this help message"
            echo ""
            echo "Roles: $ALL_ROLES"
            ;;
        *)
            # Treat argument as a role name
            get_model_for_role "$1"
            ;;
    esac
}

# Run CLI only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    _model_router_cli "$@"
fi
