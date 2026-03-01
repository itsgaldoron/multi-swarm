#!/usr/bin/env bash
# Multi-Swarm Model Router
# Maps agent roles to optimal Claude model tiers for cost optimization.
# Both sourceable (for functions) and executable (for CLI usage).

# --- Model tier constants ---
TIER_OPUS="claude-opus-4-6"
TIER_SONNET="claude-sonnet-4-6"
TIER_HAIKU="claude-haiku-4-5-20251001"

# --- Cost per 1M tokens (USD) ---
OPUS_INPUT_COST=15
OPUS_OUTPUT_COST=75
SONNET_INPUT_COST=3
SONNET_OUTPUT_COST=15
HAIKU_INPUT_COST=0.80
HAIKU_OUTPUT_COST=4

# Returns the tier name (opus/sonnet/haiku) for a given agent role.
get_model_tier() {
    local role="${1:?Usage: get_model_tier <role>}"
    case "$role" in
        swarm-lead|feature-builder|merge-coordinator)
            echo "opus" ;;
        test-writer)
            echo "sonnet" ;;
        researcher|code-reviewer)
            echo "haiku" ;;
        *)
            # Default to sonnet for unknown roles — balanced cost/quality
            echo "sonnet" ;;
    esac
}

# Returns the full model ID for a given agent role.
get_model_for_role() {
    local role="${1:?Usage: get_model_for_role <role>}"
    local tier
    tier=$(get_model_tier "$role")
    case "$tier" in
        opus)   echo "$TIER_OPUS" ;;
        sonnet) echo "$TIER_SONNET" ;;
        haiku)  echo "$TIER_HAIKU" ;;
    esac
}

# Returns all unique model IDs needed for a given set of roles (space-separated).
get_all_required_models() {
    local models=()
    local seen_opus=0 seen_sonnet=0 seen_haiku=0
    for role in "$@"; do
        local tier
        tier=$(get_model_tier "$role")
        case "$tier" in
            opus)   [[ $seen_opus -eq 0 ]]   && models+=("$TIER_OPUS")   && seen_opus=1 ;;
            sonnet) [[ $seen_sonnet -eq 0 ]] && models+=("$TIER_SONNET") && seen_sonnet=1 ;;
            haiku)  [[ $seen_haiku -eq 0 ]]  && models+=("$TIER_HAIKU")  && seen_haiku=1 ;;
        esac
    done
    echo "${models[*]}"
}

# --- CLI mode (only runs when executed, not when sourced) ---
_model_router_cli() {
    local ALL_ROLES="swarm-lead feature-builder merge-coordinator test-writer researcher code-reviewer"

    case "${1:-}" in
        --list)
            printf "%-22s %-8s %s\n" "ROLE" "TIER" "MODEL"
            printf "%-22s %-8s %s\n" "----" "----" "-----"
            for role in $ALL_ROLES; do
                printf "%-22s %-8s %s\n" "$role" "$(get_model_tier "$role")" "$(get_model_for_role "$role")"
            done
            ;;
        --tier)
            local role="${2:?Usage: model-router.sh --tier <role>}"
            get_model_tier "$role"
            ;;
        --costs)
            printf "%-8s %12s %12s\n" "TIER" "INPUT/1M" "OUTPUT/1M"
            printf "%-8s %12s %12s\n" "----" "--------" "---------"
            printf "%-8s %11s$ %11s$\n" "opus"   "$OPUS_INPUT_COST"   "$OPUS_OUTPUT_COST"
            printf "%-8s %11s$ %11s$\n" "sonnet" "$SONNET_INPUT_COST" "$SONNET_OUTPUT_COST"
            printf "%-8s %11s$ %11s$\n" "haiku"  "$HAIKU_INPUT_COST"  "$HAIKU_OUTPUT_COST"
            ;;
        --help|-h|"")
            echo "Usage: model-router.sh <role> | --list | --tier <role> | --costs"
            echo ""
            echo "Maps agent roles to optimal Claude models for cost optimization."
            echo ""
            echo "Arguments:"
            echo "  <role>          Print the model ID for the given agent role"
            echo "  --list          Print all role-to-model mappings"
            echo "  --tier <role>   Print just the tier name for a role"
            echo "  --costs         Print cost-per-1M-tokens for each tier"
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
