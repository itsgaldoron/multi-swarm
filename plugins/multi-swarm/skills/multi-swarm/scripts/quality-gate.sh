#!/usr/bin/env bash
# Quality Gate — TaskCompleted Hook
# Runs tests and lint. Exit code 2 blocks task completion with feedback.
# Exit code 0 allows completion.

WORKTREE_PATH="${WORKTREE_PATH:-$(pwd)}"
cd "$WORKTREE_PATH"

ERRORS=""

# Parse flags
PRE_COMMIT=false
QUICK_CHECK=false
case "${1:-}" in
    --pre-commit) PRE_COMMIT=true ;;
    --quick-check) QUICK_CHECK=true ;;
esac

# Quick check mode: only run diagnostics (lightweight, for PostToolUse hooks)
if [ "$QUICK_CHECK" = true ]; then
    check_diagnostics() {
        local diag_file=""
        if [ -f ".claude/diagnostics.json" ]; then
            diag_file=".claude/diagnostics.json"
        elif [ -f ".vscode/problems.json" ]; then
            diag_file=".vscode/problems.json"
        fi
        [ -z "$diag_file" ] && return 0
        command -v jq &>/dev/null || return 0
        local error_count
        error_count=$(jq '[.[] | select(.severity == "error" or .severity == 0 or .severity == 1)] | length' "$diag_file" 2>/dev/null || echo 0)
        if [ "$error_count" -gt 0 ] 2>/dev/null; then
            echo "[quality-gate] Quick check: $error_count error-level diagnostic(s) found"
            return 1
        fi
        return 0
    }
    if ! check_diagnostics; then
        echo "[quality-gate] Quick check failed — error diagnostics detected"
        exit 2
    fi
    exit 0
fi

# Get staged files for pre-commit mode
STAGED_FILES=""
if [ "$PRE_COMMIT" = true ]; then
    STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
    if [ -z "$STAGED_FILES" ]; then
        echo "[quality-gate] Pre-commit mode: no staged files found"
        exit 0
    fi
fi

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
    # In pre-commit mode, try to lint only staged files
    if [ "$PRE_COMMIT" = true ]; then
        run_lint_staged
        return $?
    fi

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

# Lint only staged files (pre-commit mode)
run_lint_staged() {
    local staged_js staged_ts staged_py staged_rs

    staged_js=$(echo "$STAGED_FILES" | grep -E '\.(js|jsx|mjs|cjs)$' || true)
    staged_ts=$(echo "$STAGED_FILES" | grep -E '\.(ts|tsx)$' || true)
    staged_py=$(echo "$STAGED_FILES" | grep -E '\.py$' || true)
    staged_rs=$(echo "$STAGED_FILES" | grep -E '\.rs$' || true)

    if [ -f "package.json" ]; then
        local lint_files
        lint_files=$(printf '%s\n%s' "$staged_js" "$staged_ts" | sed '/^$/d')
        if [ -n "$lint_files" ]; then
            if command -v npx &>/dev/null && [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ]; then
                echo "[quality-gate] Running eslint on staged files..."
                echo "$lint_files" | xargs npx eslint 2>&1 || return 1
            else
                # Fall back to project lint script
                echo "[quality-gate] Running lint on staged files..."
                if jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
                    if [ -f "pnpm-lock.yaml" ]; then
                        pnpm lint 2>&1 || return 1
                    elif [ -f "yarn.lock" ]; then
                        yarn lint 2>&1 || return 1
                    else
                        npm run lint 2>&1 || return 1
                    fi
                fi
            fi
        fi
    elif [ -n "$staged_rs" ] && [ -f "Cargo.toml" ]; then
        if command -v clippy &>/dev/null; then
            echo "[quality-gate] Running clippy (staged Rust files detected)..."
            cargo clippy -- -D warnings 2>&1 || return 1
        fi
    elif [ -n "$staged_py" ]; then
        if command -v ruff &>/dev/null; then
            echo "[quality-gate] Running ruff on staged files..."
            echo "$staged_py" | xargs ruff check 2>&1 || return 1
        fi
    fi
    return 0
}

# Check IDE diagnostics files for error-level issues
check_diagnostics() {
    local diag_file=""
    local error_count=0

    # Check common diagnostics file locations
    if [ -f ".claude/diagnostics.json" ]; then
        diag_file=".claude/diagnostics.json"
    elif [ -f ".vscode/problems.json" ]; then
        diag_file=".vscode/problems.json"
    fi

    if [ -z "$diag_file" ]; then
        # No diagnostics file found — skip silently
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "[quality-gate] Warning: jq not found, skipping diagnostics check"
        return 0
    fi

    echo "[quality-gate] Checking IDE diagnostics ($diag_file)..."

    # Parse error-level diagnostics
    # Supports formats: array of {severity: "error"|0|1, message: "..."}
    # severity=0 or severity="error" are treated as errors
    error_count=$(jq '
        [.[] | select(
            .severity == "error" or .severity == 0 or .severity == 1
        )] | length
    ' "$diag_file" 2>/dev/null || echo 0)

    if [ "$error_count" -gt 0 ] 2>/dev/null; then
        echo "[quality-gate] Found $error_count error-level diagnostic(s):"
        jq -r '
            .[] | select(.severity == "error" or .severity == 0 or .severity == 1) |
            "  \(.file // "unknown"):\(.range.start.line // "?") — \(.message // "no message")"
        ' "$diag_file" 2>/dev/null
        return 1
    fi

    echo "[quality-gate] No error-level diagnostics found"
    return 0
}

# Check code coverage against threshold
check_coverage() {
    local coverage_pct=""
    local threshold="${COVERAGE_THRESHOLD:-80}"

    # Try lcov.info (Node.js, generic)
    if [ -f "coverage/lcov.info" ]; then
        echo "[quality-gate] Checking coverage (coverage/lcov.info)..."
        local total_lines=0 hit_lines=0
        while IFS= read -r line; do
            case "$line" in
                LF:*) total_lines=$((total_lines + ${line#LF:})) ;;
                LH:*) hit_lines=$((hit_lines + ${line#LH:})) ;;
            esac
        done < "coverage/lcov.info"
        if [ "$total_lines" -gt 0 ] 2>/dev/null; then
            coverage_pct=$((hit_lines * 100 / total_lines))
        fi

    # Try coverage-summary.json (Istanbul/nyc)
    elif [ -f "coverage/coverage-summary.json" ] && command -v jq &>/dev/null; then
        echo "[quality-gate] Checking coverage (coverage/coverage-summary.json)..."
        coverage_pct=$(jq '.total.lines.pct // .total.statements.pct // empty' "coverage/coverage-summary.json" 2>/dev/null)
        # Truncate to integer
        if [ -n "$coverage_pct" ]; then
            coverage_pct=$(printf '%.0f' "$coverage_pct" 2>/dev/null || echo "")
        fi

    # Try Python .coverage (via coverage report)
    elif [ -f ".coverage" ] && command -v coverage &>/dev/null; then
        echo "[quality-gate] Checking coverage (.coverage)..."
        local cov_output
        cov_output=$(coverage report --format=total 2>/dev/null || coverage report 2>/dev/null | tail -1 | awk '{print $NF}' | tr -d '%')
        if [ -n "$cov_output" ]; then
            coverage_pct=$(printf '%.0f' "$cov_output" 2>/dev/null || echo "")
        fi

    # Try Rust tarpaulin/llvm-cov output
    elif [ -f "target/coverage/lcov.info" ]; then
        echo "[quality-gate] Checking coverage (target/coverage/lcov.info)..."
        local total_lines=0 hit_lines=0
        while IFS= read -r line; do
            case "$line" in
                LF:*) total_lines=$((total_lines + ${line#LF:})) ;;
                LH:*) hit_lines=$((hit_lines + ${line#LH:})) ;;
            esac
        done < "target/coverage/lcov.info"
        if [ "$total_lines" -gt 0 ] 2>/dev/null; then
            coverage_pct=$((hit_lines * 100 / total_lines))
        fi
    fi

    # No coverage data found — skip
    if [ -z "$coverage_pct" ]; then
        echo "[quality-gate] No coverage data found, skipping coverage check"
        return 0
    fi

    echo "[quality-gate] Coverage: ${coverage_pct}% (threshold: ${threshold}%)"

    if [ "$coverage_pct" -lt "$threshold" ] 2>/dev/null; then
        echo "[quality-gate] Coverage ${coverage_pct}% is below threshold ${threshold}%"
        return 1
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

# Check IDE diagnostics
if ! check_diagnostics; then
    ERRORS="${ERRORS}IDE diagnostics found error-level issues. Fix all errors before completing this task.\n"
fi

# Check coverage threshold
if ! check_coverage; then
    ERRORS="${ERRORS}Code coverage is below the required threshold (${COVERAGE_THRESHOLD:-80}%). Increase test coverage before completing this task.\n"
fi

# Check for TypeScript errors in Node projects
if [ -f "tsconfig.json" ] && command -v npx &>/dev/null; then
    # In pre-commit mode, only check if TS files are staged
    if [ "$PRE_COMMIT" = true ]; then
        staged_ts_files=$(echo "$STAGED_FILES" | grep -E '\.(ts|tsx)$' || true)
        if [ -n "$staged_ts_files" ]; then
            echo "[quality-gate] Checking TypeScript (staged files detected)..."
            if ! npx tsc --noEmit 2>&1; then
                ERRORS="${ERRORS}TypeScript compilation failed. Fix type errors before completing this task.\n"
            fi
        fi
    else
        echo "[quality-gate] Checking TypeScript..."
        if ! npx tsc --noEmit 2>&1; then
            ERRORS="${ERRORS}TypeScript compilation failed. Fix type errors before completing this task.\n"
        fi
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
