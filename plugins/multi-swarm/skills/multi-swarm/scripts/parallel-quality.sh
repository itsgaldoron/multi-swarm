#!/usr/bin/env bash
# Parallel Quality Gate — TaskCompleted Hook
# Runs tests, lint, and type-checking concurrently for faster feedback.
# Exit code 2 blocks task completion with feedback. Exit code 0 allows completion.

set -euo pipefail

# Require jq for JSON parsing
if ! command -v jq &>/dev/null; then
    echo "[parallel-quality] ERROR: jq is required but not found. Install jq and retry." >&2
    exit 1
fi

log_error() { echo "[parallel-quality] ERROR: $*" >&2; }

WORKTREE_PATH="${WORKTREE_PATH:-$(pwd)}"
cd "$WORKTREE_PATH" || exit 1

TMPDIR_QG=$(mktemp -d "${TMPDIR:-/tmp}/quality-gate.XXXXXX")
trap 'rm -rf "$TMPDIR_QG"' EXIT

TOTAL_START=$(date +%s)

# Detect package manager for Node projects
detect_pkg_mgr() {
    if [ -f "pnpm-lock.yaml" ]; then
        echo "pnpm"
    elif [ -f "yarn.lock" ]; then
        echo "yarn"
    else
        echo "npm"
    fi
}

# --- Job: Tests ---
job_tests() {
    local start=$(date +%s)
    local exit_code=0

    if [ -f "package.json" ]; then
        TEST_CMD=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
        if [ -n "$TEST_CMD" ]; then
            if [ "$TEST_CMD" != "echo \"Error: no test specified\" && exit 1" ]; then
                echo "[parallel-quality] Running tests..."
                local mgr=$(detect_pkg_mgr)
                if [ "$mgr" = "pnpm" ]; then
                    pnpm test 2>&1 || exit_code=1
                elif [ "$mgr" = "yarn" ]; then
                    yarn test 2>&1 || exit_code=1
                else
                    npm test 2>&1 || exit_code=1
                fi
            fi
        fi
    elif [ -f "Cargo.toml" ]; then
        echo "[parallel-quality] Running cargo test..."
        cargo test 2>&1 || exit_code=1
    elif [ -f "go.mod" ]; then
        echo "[parallel-quality] Running go test..."
        go test ./... 2>&1 || exit_code=1
    elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
        echo "[parallel-quality] Running pytest..."
        python -m pytest 2>&1 || exit_code=1
    fi

    local end=$(date +%s)
    echo "$((end - start))" > "$TMPDIR_QG/tests.time"
    return $exit_code
}

# --- Job: Lint ---
job_lint() {
    local start=$(date +%s)
    local exit_code=0

    if [ -f "package.json" ]; then
        local lint_cmd
        lint_cmd=$(jq -r '.scripts.lint // empty' package.json 2>/dev/null)
        if [ -n "$lint_cmd" ]; then
            echo "[parallel-quality] Running lint..."
            local mgr=$(detect_pkg_mgr)
            if [ "$mgr" = "pnpm" ]; then
                pnpm lint 2>&1 || exit_code=1
            elif [ "$mgr" = "yarn" ]; then
                yarn lint 2>&1 || exit_code=1
            else
                npm run lint 2>&1 || exit_code=1
            fi
        fi
    elif [ -f "Cargo.toml" ]; then
        if command -v clippy &>/dev/null; then
            echo "[parallel-quality] Running clippy..."
            cargo clippy -- -D warnings 2>&1 || exit_code=1
        fi
    elif [ -f "pyproject.toml" ] || [ -f "setup.cfg" ]; then
        if command -v ruff &>/dev/null; then
            echo "[parallel-quality] Running ruff..."
            ruff check . 2>&1 || exit_code=1
        fi
    fi

    local end=$(date +%s)
    echo "$((end - start))" > "$TMPDIR_QG/lint.time"
    return $exit_code
}

# --- Job: Type Check ---
job_typecheck() {
    local start=$(date +%s)
    local exit_code=0

    if [ -f "tsconfig.json" ] && command -v npx &>/dev/null; then
        echo "[parallel-quality] Checking TypeScript..."
        npx tsc --noEmit 2>&1 || exit_code=1
    elif [ -f "Cargo.toml" ]; then
        echo "[parallel-quality] Running cargo check..."
        cargo check 2>&1 || exit_code=1
    elif [ -f "pyproject.toml" ]; then
        if command -v mypy &>/dev/null; then
            echo "[parallel-quality] Running mypy..."
            mypy . 2>&1 || exit_code=1
        elif command -v pyright &>/dev/null; then
            echo "[parallel-quality] Running pyright..."
            pyright 2>&1 || exit_code=1
        fi
    elif [ -f "go.mod" ]; then
        echo "[parallel-quality] Running go vet..."
        go vet ./... 2>&1 || exit_code=1
    fi

    local end=$(date +%s)
    echo "$((end - start))" > "$TMPDIR_QG/typecheck.time"
    return $exit_code
}

# Launch all checks in parallel, capturing output to temp files
job_tests   > "$TMPDIR_QG/tests.out"   2>&1 &
PID_TESTS=$!

job_lint    > "$TMPDIR_QG/lint.out"     2>&1 &
PID_LINT=$!

job_typecheck > "$TMPDIR_QG/typecheck.out" 2>&1 &
PID_TYPECHECK=$!

echo "[parallel-quality] Running tests, lint, and type-check in parallel..."

# Wait for each job and capture exit codes
wait $PID_TESTS
EXIT_TESTS=$?

wait $PID_LINT
EXIT_LINT=$?

wait $PID_TYPECHECK
EXIT_TYPECHECK=$?

TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END - TOTAL_START))

# Read per-job timing (default 0 if file missing)
TIME_TESTS=$(cat "$TMPDIR_QG/tests.time" 2>/dev/null || echo "0")
TIME_LINT=$(cat "$TMPDIR_QG/lint.time" 2>/dev/null || echo "0")
TIME_TYPECHECK=$(cat "$TMPDIR_QG/typecheck.time" 2>/dev/null || echo "0")
SEQUENTIAL_TOTAL=$((TIME_TESTS + TIME_LINT + TIME_TYPECHECK))

# Report results
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        PARALLEL QUALITY GATE REPORT      ║"
echo "╠══════════════════════════════════════════╣"

ERRORS=""

report_check() {
    local name="$1" exit_code="$2" elapsed="$3" outfile="$4"
    local status
    if [ "$exit_code" -eq 0 ]; then
        status="PASS"
    else
        status="FAIL"
    fi
    printf "║  %-12s  %s  (%ds)  %s\n" "$name" "$status" "$elapsed" "║"
}

report_check "Tests"     "$EXIT_TESTS"     "$TIME_TESTS"     "$TMPDIR_QG/tests.out"
report_check "Lint"      "$EXIT_LINT"      "$TIME_LINT"      "$TMPDIR_QG/lint.out"
report_check "TypeCheck" "$EXIT_TYPECHECK" "$TIME_TYPECHECK" "$TMPDIR_QG/typecheck.out"

echo "╠══════════════════════════════════════════╣"
printf "║  Total: %ds (saved ~%ds vs sequential)  ║\n" "$TOTAL_ELAPSED" "$((SEQUENTIAL_TOTAL - TOTAL_ELAPSED))"
echo "╚══════════════════════════════════════════╝"

# Print output for failed checks
if [ "$EXIT_TESTS" -ne 0 ]; then
    echo ""
    echo "=== TEST FAILURES ==="
    cat "$TMPDIR_QG/tests.out"
    ERRORS="${ERRORS}Tests failed. Fix all test failures before completing this task.\n"
fi

if [ "$EXIT_LINT" -ne 0 ]; then
    echo ""
    echo "=== LINT FAILURES ==="
    cat "$TMPDIR_QG/lint.out"
    ERRORS="${ERRORS}Lint failed. Fix all lint errors before completing this task.\n"
fi

if [ "$EXIT_TYPECHECK" -ne 0 ]; then
    echo ""
    echo "=== TYPE CHECK FAILURES ==="
    cat "$TMPDIR_QG/typecheck.out"
    ERRORS="${ERRORS}Type checking failed. Fix type errors before completing this task.\n"
fi

if [ -n "$ERRORS" ]; then
    echo ""
    echo "=== QUALITY GATE FAILED ==="
    echo -e "$ERRORS"
    echo "Task completion blocked. Fix the issues above and try again."
    exit 2
fi

echo ""
echo "[parallel-quality] All checks passed"
exit 0
