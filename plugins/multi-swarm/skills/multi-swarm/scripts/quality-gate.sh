#!/usr/bin/env bash
# Quality Gate — TaskCompleted Hook
# Runs tests and lint. Exit code 2 blocks task completion with feedback.
# Exit code 0 allows completion.

WORKTREE_PATH="${WORKTREE_PATH:-$(pwd)}"
cd "$WORKTREE_PATH"

ERRORS=""

# Auto-detect test command
run_tests() {
    if [ -f "package.json" ]; then
        # Check for specific test scripts
        if jq -e '.scripts.test' package.json >/dev/null 2>&1; then
            TEST_CMD=$(jq -r '.scripts.test' package.json)
            if [ "$TEST_CMD" != "echo \"Error: no test specified\" && exit 1" ]; then
                echo "[quality-gate] Running tests..."
                if [ -f "pnpm-lock.yaml" ]; then
                    pnpm test 2>&1 || return 1
                elif [ -f "yarn.lock" ]; then
                    yarn test 2>&1 || return 1
                else
                    npm test 2>&1 || return 1
                fi
            fi
        fi
    elif [ -f "Cargo.toml" ]; then
        echo "[quality-gate] Running cargo test..."
        cargo test 2>&1 || return 1
    elif [ -f "go.mod" ]; then
        echo "[quality-gate] Running go test..."
        go test ./... 2>&1 || return 1
    elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
        echo "[quality-gate] Running pytest..."
        python -m pytest 2>&1 || return 1
    fi
    return 0
}

# Auto-detect lint command
run_lint() {
    if [ -f "package.json" ]; then
        if jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
            echo "[quality-gate] Running lint..."
            if [ -f "pnpm-lock.yaml" ]; then
                pnpm lint 2>&1 || return 1
            elif [ -f "yarn.lock" ]; then
                yarn lint 2>&1 || return 1
            else
                npm run lint 2>&1 || return 1
            fi
        fi
    elif [ -f "Cargo.toml" ]; then
        if command -v clippy &>/dev/null; then
            echo "[quality-gate] Running clippy..."
            cargo clippy -- -D warnings 2>&1 || return 1
        fi
    elif [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
        if command -v ruff &>/dev/null; then
            echo "[quality-gate] Running ruff..."
            ruff check . 2>&1 || return 1
        fi
    fi
    return 0
}

# Run tests
if ! run_tests; then
    ERRORS="${ERRORS}Tests failed. Fix all test failures before completing this task.\n"
fi

# Run lint
if ! run_lint; then
    ERRORS="${ERRORS}Lint failed. Fix all lint errors before completing this task.\n"
fi

# Check for TypeScript errors in Node projects
if [ -f "tsconfig.json" ] && command -v npx &>/dev/null; then
    echo "[quality-gate] Checking TypeScript..."
    if ! npx tsc --noEmit 2>&1; then
        ERRORS="${ERRORS}TypeScript compilation failed. Fix type errors before completing this task.\n"
    fi
fi

if [ -n "$ERRORS" ]; then
    echo ""
    echo "=== QUALITY GATE FAILED ==="
    echo -e "$ERRORS"
    echo "Task completion blocked. Fix the issues above and try again."
    exit 2
fi

echo "[quality-gate] All checks passed"
exit 0
