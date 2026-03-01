#!/usr/bin/env bash
set -euo pipefail

# Multi-Swarm Quality Report
# Usage: quality-report.sh <run-id>
# Generates per-swarm quality scorecards with grades

RUN_ID="${1:-}"
if [ -z "$RUN_ID" ]; then
    echo "Usage: quality-report.sh <run-id>"
    exit 1
fi

STATE_DIR="$HOME/.claude/multi-swarm/state/${RUN_ID}"
if [ ! -d "$STATE_DIR/swarms" ]; then
    echo "Error: No state found for run $RUN_ID"
    exit 1
fi

COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-80}"

# ── Helpers ────────────────────────────────────────────────────────

color_pass() { printf "\033[32m%s\033[0m" "$1"; }
color_fail() { printf "\033[31m%s\033[0m" "$1"; }
color_warn() { printf "\033[33m%s\033[0m" "$1"; }
color_grade() {
    case "$1" in
        A) printf "\033[32m%s\033[0m" "$1" ;;
        B) printf "\033[36m%s\033[0m" "$1" ;;
        C) printf "\033[33m%s\033[0m" "$1" ;;
        D) printf "\033[33m%s\033[0m" "$1" ;;
        F) printf "\033[31m%s\033[0m" "$1" ;;
        *) printf "%s" "$1" ;;
    esac
}

status_icon() {
    case "$1" in
        pass) color_pass "PASS" ;;
        fail) color_fail "FAIL" ;;
        skip) printf "\033[90mSKIP\033[0m" ;;
    esac
}

# Parse coverage percentage from lcov.info
parse_lcov() {
    local file="$1"
    local lines_found=0 lines_hit=0
    while IFS= read -r line; do
        case "$line" in
            LF:*) lines_found=$((lines_found + ${line#LF:})) ;;
            LH:*) lines_hit=$((lines_hit + ${line#LH:})) ;;
        esac
    done < "$file"
    if [ "$lines_found" -gt 0 ]; then
        echo $((lines_hit * 100 / lines_found))
    else
        echo "-1"
    fi
}

# Parse coverage from coverage-summary.json
parse_coverage_summary() {
    local file="$1"
    jq -r '.total.lines.pct // .total.statements.pct // -1' "$file" 2>/dev/null | awk '{printf "%d", $1}'
}

# Find and parse coverage for a worktree path
get_coverage() {
    local worktree="$1"
    # Try common coverage file locations
    for cov_file in \
        "$worktree/coverage/lcov.info" \
        "$worktree/lcov.info" \
        "$worktree/coverage/lcov/lcov.info"; do
        if [ -f "$cov_file" ]; then
            parse_lcov "$cov_file"
            return
        fi
    done
    for cov_file in \
        "$worktree/coverage/coverage-summary.json" \
        "$worktree/coverage-summary.json"; do
        if [ -f "$cov_file" ]; then
            parse_coverage_summary "$cov_file"
            return
        fi
    done
    # Python coverage
    if [ -f "$worktree/.coverage" ] && command -v python3 &>/dev/null; then
        local pct
        pct=$(cd "$worktree" && python3 -m coverage report --format=total 2>/dev/null || echo "-1")
        echo "${pct%\%}"
        return
    fi
    echo "-1"
}

# Calculate grade from component scores
# Components: tests (30%), lint (20%), typecheck (20%), coverage (30%)
calculate_grade() {
    local test_status="$1" lint_status="$2" type_status="$3" coverage="$4"
    local score=0

    case "$test_status" in
        pass) score=$((score + 30)) ;;
        skip) score=$((score + 15)) ;;
    esac
    case "$lint_status" in
        pass) score=$((score + 20)) ;;
        skip) score=$((score + 10)) ;;
    esac
    case "$type_status" in
        pass) score=$((score + 20)) ;;
        skip) score=$((score + 10)) ;;
    esac

    if [ "$coverage" -ge 0 ]; then
        if [ "$coverage" -ge 90 ]; then
            score=$((score + 30))
        elif [ "$coverage" -ge 80 ]; then
            score=$((score + 25))
        elif [ "$coverage" -ge 60 ]; then
            score=$((score + 15))
        elif [ "$coverage" -ge 40 ]; then
            score=$((score + 10))
        else
            score=$((score + 5))
        fi
    else
        score=$((score + 15))
    fi

    if [ "$score" -ge 90 ]; then echo "A"
    elif [ "$score" -ge 80 ]; then echo "B"
    elif [ "$score" -ge 65 ]; then echo "C"
    elif [ "$score" -ge 50 ]; then echo "D"
    else echo "F"
    fi
}

# ── Report ─────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Multi-Swarm Quality Report                     ║"
echo "║  Run: $(printf '%-52s' "$RUN_ID") ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo ""

total_swarms=0
total_pass=0
total_fail=0
grade_sum=0
coverage_count=0
coverage_sum=0
below_threshold=0

for status_file in "$STATE_DIR"/swarms/*/status.json; do
    [ -f "$status_file" ] || continue
    total_swarms=$((total_swarms + 1))

    SWARM_DIR=$(dirname "$status_file")
    SWARM_NAME=$(basename "$SWARM_DIR")
    WORKTREE=$(jq -r '.worktree // ""' "$status_file" 2>/dev/null)
    STATUS=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null)
    BRANCH=$(jq -r '.branch // "N/A"' "$status_file" 2>/dev/null)

    # Read quality gate results from status.json if available
    test_status="skip"
    lint_status="skip"
    type_status="skip"
    test_detail=""
    coverage=-1

    if jq -e '.quality' "$status_file" >/dev/null 2>&1; then
        test_status=$(jq -r '.quality.tests // "skip"' "$status_file" 2>/dev/null)
        lint_status=$(jq -r '.quality.lint // "skip"' "$status_file" 2>/dev/null)
        type_status=$(jq -r '.quality.typecheck // "skip"' "$status_file" 2>/dev/null)
        test_detail=$(jq -r '.quality.testDetail // ""' "$status_file" 2>/dev/null)
    fi

    # Try to get coverage from worktree files
    if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
        cov=$(get_coverage "$WORKTREE")
        if [ "$cov" -ge 0 ] 2>/dev/null; then
            coverage=$cov
        fi
    fi

    # Also check status.json for stored coverage
    if [ "$coverage" -lt 0 ]; then
        stored_cov=$(jq -r '.quality.coverage // -1' "$status_file" 2>/dev/null)
        if [ "$stored_cov" != "null" ] && [ "$stored_cov" -ge 0 ] 2>/dev/null; then
            coverage=$stored_cov
        fi
    fi

    GRADE=$(calculate_grade "$test_status" "$lint_status" "$type_status" "$coverage")

    # Track aggregates
    case "$GRADE" in
        A) grade_sum=$((grade_sum + 4)); total_pass=$((total_pass + 1)) ;;
        B) grade_sum=$((grade_sum + 3)); total_pass=$((total_pass + 1)) ;;
        C) grade_sum=$((grade_sum + 2)) ;;
        D) grade_sum=$((grade_sum + 1)); total_fail=$((total_fail + 1)) ;;
        F) grade_sum=$((grade_sum + 0)); total_fail=$((total_fail + 1)) ;;
    esac

    if [ "$coverage" -ge 0 ]; then
        coverage_count=$((coverage_count + 1))
        coverage_sum=$((coverage_sum + coverage))
        if [ "$coverage" -lt "$COVERAGE_THRESHOLD" ]; then
            below_threshold=$((below_threshold + 1))
        fi
    fi

    # ── Render Scorecard ───────────────────────────────────────
    echo "┌──────────────────────────────────────────────────────────┐"
    printf "│  %-40s  Grade: " "$SWARM_NAME"
    color_grade "$GRADE"
    printf "       │\n"
    echo "├──────────────────────────────────────────────────────────┤"

    printf "│  Tests:      "
    status_icon "$test_status"
    if [ -n "$test_detail" ] && [ "$test_detail" != "null" ]; then
        printf "  %-38s│\n" "($test_detail)"
    else
        printf "  %-38s│\n" ""
    fi

    printf "│  Lint:       "
    status_icon "$lint_status"
    printf "  %-38s│\n" ""

    printf "│  TypeCheck:  "
    status_icon "$type_status"
    printf "  %-38s│\n" ""

    printf "│  Coverage:   "
    if [ "$coverage" -ge 0 ]; then
        if [ "$coverage" -ge "$COVERAGE_THRESHOLD" ]; then
            color_pass "${coverage}%"
        else
            color_fail "${coverage}%"
            printf " (below %s%% threshold)" "$COVERAGE_THRESHOLD"
        fi
        # Pad remaining space
        if [ "$coverage" -lt "$COVERAGE_THRESHOLD" ]; then
            printf "%-14s│\n" ""
        else
            printf "  %-38s│\n" ""
        fi
    else
        printf "\033[90m%-42s\033[0m│\n" "N/A"
    fi

    printf "│  Status:     %-42s│\n" "$STATUS"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""
done

if [ "$total_swarms" -eq 0 ]; then
    echo "  No swarms found for run $RUN_ID"
    echo ""
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 0
fi

# ── Aggregate Summary ──────────────────────────────────────────────

avg_grade_num=$((grade_sum / total_swarms))
case "$avg_grade_num" in
    4) avg_grade="A" ;;
    3) avg_grade="B" ;;
    2) avg_grade="C" ;;
    1) avg_grade="D" ;;
    *) avg_grade="F" ;;
esac

echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                      Summary                               ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  Total Swarms:      %-39s║\n" "$total_swarms"
printf "║  Passing (A/B):     %-39s║\n" "$total_pass"
printf "║  Failing (D/F):     %-39s║\n" "$total_fail"
printf "║  Average Grade:     "
color_grade "$avg_grade"
printf "%-38s║\n" ""

if [ "$coverage_count" -gt 0 ]; then
    avg_coverage=$((coverage_sum / coverage_count))
    printf "║  Avg Coverage:      "
    if [ "$avg_coverage" -ge "$COVERAGE_THRESHOLD" ]; then
        color_pass "${avg_coverage}%"
    else
        color_fail "${avg_coverage}%"
    fi
    printf "%-37s║\n" ""
    printf "║  Below Threshold:   %-39s║\n" "${below_threshold}/${coverage_count} (threshold: ${COVERAGE_THRESHOLD}%)"
else
    printf "║  Coverage:          %-39s║\n" "No coverage data found"
fi

echo "╚══════════════════════════════════════════════════════════════╝"

# Exit with error if any swarm has D/F grade
if [ "$total_fail" -gt 0 ]; then
    echo ""
    echo "Quality gate: ${total_fail} swarm(s) below acceptable quality."
    exit 1
fi
