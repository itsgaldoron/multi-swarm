#!/usr/bin/env bash
set -euo pipefail

# Worktree Setup Hook
# Called automatically when a worktree is created
# Auto-detects package manager, installs dependencies, copies .env files

WORKTREE_PATH="${WORKTREE_PATH:-$(pwd)}"
SOURCE_PROJECT="${SOURCE_PROJECT:-$(git rev-parse --show-toplevel 2>/dev/null || echo '')}"
GLOBAL_CONFIG="$HOME/.claude/multi-swarm/config.json"

echo "[worktree-setup] Setting up worktree: $WORKTREE_PATH"

cd "$WORKTREE_PATH"

# Read config
INSTALL_DEPS=$(jq -r '.setup.installDependencies // true' "$GLOBAL_CONFIG" 2>/dev/null || echo "true")
COPY_ENV=$(jq -r '.setup.copyEnvFiles // true' "$GLOBAL_CONFIG" 2>/dev/null || echo "true")
ENV_FILES=$(jq -r '.setup.envFilesToCopy // [".env", ".env.local", ".env.development.local"] | .[]' "$GLOBAL_CONFIG" 2>/dev/null || echo -e ".env\n.env.local\n.env.development.local")

# Auto-detect package manager and install dependencies
if [ "$INSTALL_DEPS" = "true" ]; then
    if [ -f "pnpm-lock.yaml" ]; then
        echo "[worktree-setup] Detected pnpm, installing dependencies..."
        pnpm install --frozen-lockfile 2>/dev/null || pnpm install
    elif [ -f "yarn.lock" ]; then
        echo "[worktree-setup] Detected yarn, installing dependencies..."
        yarn install --frozen-lockfile 2>/dev/null || yarn install
    elif [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
        echo "[worktree-setup] Detected bun, installing dependencies..."
        bun install --frozen-lockfile 2>/dev/null || bun install
    elif [ -f "package-lock.json" ]; then
        echo "[worktree-setup] Detected npm, installing dependencies..."
        npm ci 2>/dev/null || npm install
    elif [ -f "Cargo.toml" ]; then
        echo "[worktree-setup] Detected Cargo, building..."
        cargo build 2>/dev/null || true
    elif [ -f "go.mod" ]; then
        echo "[worktree-setup] Detected Go modules, downloading..."
        go mod download 2>/dev/null || true
    elif [ -f "requirements.txt" ]; then
        echo "[worktree-setup] Detected pip, installing..."
        pip install -r requirements.txt 2>/dev/null || true
    elif [ -f "pyproject.toml" ]; then
        echo "[worktree-setup] Detected Python project..."
        if command -v uv &>/dev/null; then
            uv sync 2>/dev/null || true
        elif [ -f "poetry.lock" ]; then
            poetry install 2>/dev/null || true
        else
            pip install -e . 2>/dev/null || true
        fi
    elif [ -f "Gemfile" ]; then
        echo "[worktree-setup] Detected Bundler, installing..."
        bundle install 2>/dev/null || true
    else
        echo "[worktree-setup] No recognized package manager found, skipping dependency install"
    fi
fi

# Copy .env files from source project
if [ "$COPY_ENV" = "true" ] && [ -n "$SOURCE_PROJECT" ] && [ -d "$SOURCE_PROJECT" ]; then
    echo "$ENV_FILES" | while read -r envfile; do
        if [ -n "$envfile" ] && [ -f "${SOURCE_PROJECT}/${envfile}" ]; then
            cp "${SOURCE_PROJECT}/${envfile}" "${WORKTREE_PATH}/${envfile}"
            echo "[worktree-setup] Copied ${envfile} from source project"
        fi
    done
fi

# Assign deterministic port based on worktree name
WORKTREE_NAME=$(basename "$WORKTREE_PATH")
PORT_OFFSET=$(echo "$WORKTREE_NAME" | cksum | cut -d' ' -f1)
PORT=$((3100 + PORT_OFFSET % 100))
export PORT
echo "[worktree-setup] Assigned port: $PORT"

# Run project-specific setup if it exists
PROJECT_SETUP="${SOURCE_PROJECT}/.multi-swarm/setup.sh"
if [ -f "$PROJECT_SETUP" ]; then
    echo "[worktree-setup] Running project-specific setup..."
    bash "$PROJECT_SETUP" "$WORKTREE_PATH"
fi

echo "[worktree-setup] Setup complete for $WORKTREE_PATH"
