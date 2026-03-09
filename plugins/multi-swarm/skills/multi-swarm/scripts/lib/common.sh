#!/usr/bin/env bash
# lib/common.sh — Shared utility functions for multi-swarm scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Functions Provided:
#   log <level> <message...>       — Timestamped log to stdout
#   log_error <message...>         — Error log to stderr
#   phase_color <phase>            — ANSI color code for phase name
#   require_command <cmd>          — Assert command exists in PATH
#   validate_manifest <path>       — Validate manifest file exists and is valid JSON
#   retry_with_backoff <max> <base_delay> <cmd...> — Retry with exponential backoff
#   setup_worktree <path> <root>   — Install deps, copy env files, run project setup
#   setup_cleanup_trap [fn]        — Set up signal handling with cleanup function

# Guard against double-sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# --- Logging ---

log() {
    local level="${1:-INFO}"
    shift
    printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

log_error() {
    printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# --- Phase Colors ---

phase_color() {
    local phase="${1:?Usage: phase_color <phase>}"
    case "$phase" in
        analyzing) printf '\033[34m' ;;  # blue
        planning)  printf '\033[33m' ;;  # yellow
        working)   printf '\033[33m' ;;  # yellow
        building)  printf '\033[33m' ;;  # yellow
        testing)   printf '\033[36m' ;;  # cyan
        merging)   printf '\033[35m' ;;  # magenta
        done)      printf '\033[32m' ;;  # green
        failed)    printf '\033[31m' ;;  # red
        error)     printf '\033[31m' ;;  # red
        *)         printf '\033[0m'  ;;  # reset
    esac
}

# --- Command Checks ---

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command '$cmd' not found in PATH"
        exit 1
    fi
}

# --- Manifest Validation ---

validate_manifest() {
    local manifest="$1"
    if [ ! -f "$manifest" ]; then
        log_error "Manifest file not found: $manifest"
        exit 1
    fi
    if ! jq empty "$manifest" 2>/dev/null; then
        log_error "Manifest is not valid JSON: $manifest"
        exit 1
    fi
}

# --- Retry Logic ---

retry_with_backoff() {
    local max_attempts="${1:?Max attempts required}"
    local base_delay="${2:?Base delay required}"
    shift 2
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if "$@"; then
            return 0
        fi
        local delay=$(( base_delay * (2 ** (attempt - 1)) ))
        log "WARN" "Command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    log_error "Command failed after $max_attempts attempts: $*"
    return 1
}

# --- Worktree Setup ---

setup_worktree() {
    local worktree_path="$1"
    local project_root="$2"

    (
        cd "$worktree_path"
        GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"
        INSTALL_DEPS=$(jq -r '.setup.installDependencies // true' "$GLOBAL_CONFIG" 2>/dev/null || echo "true")
        COPY_ENV=$(jq -r '.setup.copyEnvFiles // true' "$GLOBAL_CONFIG" 2>/dev/null || echo "true")
        ENV_FILES=$(jq -r '.setup.envFilesToCopy // [".env", ".env.local", ".env.development.local"] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || echo -e ".env\n.env.local\n.env.development.local")

        if [ "$INSTALL_DEPS" = "true" ]; then
            if [ -f "pnpm-lock.yaml" ]; then
                pnpm install --frozen-lockfile 2>/dev/null || pnpm install
            elif [ -f "yarn.lock" ]; then
                yarn install --frozen-lockfile 2>/dev/null || yarn install
            elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
                bun install --frozen-lockfile 2>/dev/null || bun install
            elif [ -f "package-lock.json" ]; then
                npm ci 2>/dev/null || npm install
            elif [ -f "Cargo.toml" ]; then
                cargo build 2>/dev/null || true
            elif [ -f "go.mod" ]; then
                go mod download 2>/dev/null || true
            elif [ -f "requirements.txt" ]; then
                pip install -r requirements.txt 2>/dev/null || true
            elif [ -f "pyproject.toml" ]; then
                if command -v uv &>/dev/null; then
                    uv sync 2>/dev/null || true
                elif [ -f "poetry.lock" ]; then
                    poetry install 2>/dev/null || true
                else
                    pip install -e . 2>/dev/null || true
                fi
            elif [ -f "Gemfile" ]; then
                bundle install 2>/dev/null || true
            fi
        fi

        if [ "$COPY_ENV" = "true" ] && [ -d "$project_root" ]; then
            printf '%s\n' "$ENV_FILES" | while read -r envfile; do
                if [ -n "$envfile" ] && [ -f "${project_root}/${envfile}" ]; then
                    cp "${project_root}/${envfile}" "${worktree_path}/${envfile}"
                    log "INFO" "Copied ${envfile} from source project"
                fi
            done
        fi

        # Run project-specific setup if it exists
        if [ -f "${project_root}/.multi-swarm/setup.sh" ]; then
            bash "${project_root}/.multi-swarm/setup.sh" "$worktree_path"
        fi
    )
}

# --- Signal Handling ---

setup_cleanup_trap() {
    local cleanup_fn="${1:-_default_cleanup}"
    trap "$cleanup_fn" EXIT INT TERM HUP
}

_default_cleanup() {
    :
}
