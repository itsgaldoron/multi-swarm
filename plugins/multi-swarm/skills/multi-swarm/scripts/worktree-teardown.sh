#!/usr/bin/env bash
set -euo pipefail

# Worktree Teardown Hook
# Called automatically when a worktree is removed
# Collects artifacts and cleans up heavy directories
#
# Environment Variables:
#   WORKTREE_PATH     — Path to the worktree being torn down (optional, default: current directory)
#   SOURCE_PROJECT    — Path to the source/main project (optional, auto-detected via git)

WORKTREE_PATH="${WORKTREE_PATH:-$(pwd)}"
WORKTREE_NAME=$(basename "$WORKTREE_PATH")
ARTIFACTS_DIR="${HOME}/.claude/artifacts/${WORKTREE_NAME}"
SOURCE_PROJECT="${SOURCE_PROJECT:-$(git rev-parse --show-toplevel 2>/dev/null || echo '')}"

echo "[worktree-teardown] Tearing down: $WORKTREE_PATH"

# Collect artifacts before cleanup
mkdir -p "$ARTIFACTS_DIR"

# Collect coverage reports
for coverage_dir in coverage .nyc_output htmlcov; do
    if [ -d "${WORKTREE_PATH}/${coverage_dir}" ]; then
        cp -r "${WORKTREE_PATH}/${coverage_dir}" "${ARTIFACTS_DIR}/" 2>/dev/null || true
        echo "[worktree-teardown] Collected ${coverage_dir}"
    fi
done

# Collect test results
for result_file in test-results.xml junit.xml test-report.html; do
    if [ -f "${WORKTREE_PATH}/${result_file}" ]; then
        cp "${WORKTREE_PATH}/${result_file}" "${ARTIFACTS_DIR}/" 2>/dev/null || true
        echo "[worktree-teardown] Collected ${result_file}"
    fi
done

# Collect build output info (just a manifest, not the full build)
if [ -d "${WORKTREE_PATH}/.next" ]; then
    ls -la "${WORKTREE_PATH}/.next/" > "${ARTIFACTS_DIR}/next-build-manifest.txt" 2>/dev/null || true
fi
if [ -d "${WORKTREE_PATH}/dist" ]; then
    ls -la "${WORKTREE_PATH}/dist/" > "${ARTIFACTS_DIR}/dist-manifest.txt" 2>/dev/null || true
fi

# Clean up heavy directories to free disk space
echo "[worktree-teardown] Cleaning heavy directories..."
for dir in node_modules .next dist build target __pycache__ .pytest_cache .tox .venv venv; do
    if [ -d "${WORKTREE_PATH}/${dir}" ]; then
        rm -rf "${WORKTREE_PATH}/${dir}"
        echo "[worktree-teardown] Removed ${dir}"
    fi
done

# Remove copied .env files (security cleanup)
for envfile in .env .env.local .env.development.local .env.test.local .env.production.local; do
    if [ -f "${WORKTREE_PATH}/${envfile}" ]; then
        rm -f "${WORKTREE_PATH}/${envfile}"
        echo "[worktree-teardown] Removed ${envfile}"
    fi
done

# Run project-specific teardown if it exists
PROJECT_TEARDOWN="${SOURCE_PROJECT}/.multi-swarm/teardown.sh"
if [ -f "$PROJECT_TEARDOWN" ]; then
    echo "[worktree-teardown] Running project-specific teardown..."
    bash "$PROJECT_TEARDOWN" "$WORKTREE_PATH"
fi

echo "[worktree-teardown] Teardown complete. Artifacts saved to $ARTIFACTS_DIR"
