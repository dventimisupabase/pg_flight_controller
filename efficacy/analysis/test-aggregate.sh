#!/usr/bin/env bash
# Tests for aggregate.sh — synthetic known-answer inputs.
#
# Generates verdict.json files with predetermined values, runs the
# aggregation pipeline, and asserts the cell verdict.
#
# Usage: ./efficacy/analysis/test-aggregate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGGREGATE="$SCRIPT_DIR/aggregate.sh"

PASS=0
FAIL=0
TESTS=()

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        TESTS+=("ok - $label")
    else
        FAIL=$((FAIL + 1))
        TESTS+=("FAIL - $label (expected '$expected', got '$actual')")
    fi
}

gen_verdict() {
    local file="$1" verdict="$2" gc="$3"
    local cost_breach="${4:-false}" safety_holds="${5:-true}" safety_eval="${6:-true}"
    local av_breach="${7:-false}" mutation_breach="${8:-false}"
    local windows_scored="${9:-8}"
    cat > "$file" <<EOJSON
{
  "verdict": "$verdict",
  "median_gap_closed": $gc,
  "total_windows": 10,
  "warmup_discarded": 2,
  "graded_windows": 8,
  "windows_dropped_denom": 0,
  "windows_scored": $windows_scored,
  "cost_ceiling_breach": $cost_breach,
  "av_ceiling_breach": $av_breach,
  "mutation_ceiling_breach": $mutation_breach,
  "defaults_av_count": 5,
  "pgfc_av_count": 8,
  "pgfc_applied": 3,
  "safety_floor_evaluated": $safety_eval,
  "safety_floor_holds": $safety_holds,
  "freeze_max_age": 200000000,
  "worst_xid_age": 100,
  "per_window": []
}
EOJSON
}

# =========================================================================
# Test 1: All strong pass
#
# 3 seeds: gc = 0.40, 0.45, 0.50
# Median = 0.45 → strong_pass
# =========================================================================

test_all_strong_pass() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/s3" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "strong_pass" 0.40
    gen_verdict "$tmp/s2/verdict.json" "strong_pass" 0.45
    gen_verdict "$tmp/s3/verdict.json" "strong_pass" 0.50

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" "$tmp/s3/verdict.json" 2>/dev/null

    local cell_verdict gc
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    gc=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['median_gap_closed'])")
    assert_eq "all strong pass: cell_verdict" "strong_pass" "$cell_verdict"
    assert_eq "all strong pass: median_gc=0.45" "0.45" "$gc"

    local iqr_low iqr_high
    iqr_low=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['iqr_low'])")
    iqr_high=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['iqr_high'])")
    assert_eq "all strong pass: iqr_low=0.425" "0.425" "$iqr_low"
    assert_eq "all strong pass: iqr_high=0.475" "0.475" "$iqr_high"
}

# =========================================================================
# Test 2: Bare pass
#
# 3 seeds: gc = 0.0, 0.1, 0.2
# Median = 0.1 → pass (>= 0 but < 0.25)
# =========================================================================

test_bare_pass() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/s3" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "pass" 0.0
    gen_verdict "$tmp/s2/verdict.json" "pass" 0.1
    gen_verdict "$tmp/s3/verdict.json" "pass" 0.2

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" "$tmp/s3/verdict.json" 2>/dev/null

    local cell_verdict gc
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    gc=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['median_gap_closed'])")
    assert_eq "bare pass: cell_verdict" "pass" "$cell_verdict"
    assert_eq "bare pass: median_gc=0.1" "0.1" "$gc"
}

# =========================================================================
# Test 3: One seed negative, median still positive
#
# 3 seeds: gc = -0.10, 0.30, 0.40
# Median = 0.30 → strong_pass (individual seed failure doesn't override)
# =========================================================================

test_one_seed_negative() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/s3" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "fail" -0.10
    gen_verdict "$tmp/s2/verdict.json" "strong_pass" 0.30
    gen_verdict "$tmp/s3/verdict.json" "strong_pass" 0.40

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" "$tmp/s3/verdict.json" 2>/dev/null

    local cell_verdict gc
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    gc=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['median_gap_closed'])")
    assert_eq "one seed negative: cell_verdict" "strong_pass" "$cell_verdict"
    assert_eq "one seed negative: median_gc=0.3" "0.3" "$gc"
}

# =========================================================================
# Test 4: Cost ceiling breach in one seed
#
# 3 seeds: gc = 0.40, 0.45, 0.50 but seed 2 has cost_ceiling_breach=true.
# Worst-case gate → any_cost_ceiling_breach → fail (even though gc > 0).
# =========================================================================

test_cost_ceiling_one_seed() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/s3" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "strong_pass" 0.40
    gen_verdict "$tmp/s2/verdict.json" "fail" 0.45 "true"
    gen_verdict "$tmp/s3/verdict.json" "strong_pass" 0.50

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" "$tmp/s3/verdict.json" 2>/dev/null

    local cell_verdict breach
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    breach=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['any_cost_ceiling_breach'])")
    assert_eq "cost ceiling one seed: cell_verdict" "fail" "$cell_verdict"
    assert_eq "cost ceiling one seed: any_cost_ceiling_breach" "True" "$breach"
}

# =========================================================================
# Test 5: Safety floor violation in one seed
#
# 3 seeds: gc = 0.40, 0.45, 0.50 but seed 3 has safety_floor_holds=false.
# Worst-case gate → fail.
# =========================================================================

test_safety_floor_one_seed() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/s3" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "strong_pass" 0.40
    gen_verdict "$tmp/s2/verdict.json" "strong_pass" 0.45
    gen_verdict "$tmp/s3/verdict.json" "fail" 0.50 "false" "false" "true"

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" "$tmp/s3/verdict.json" 2>/dev/null

    local cell_verdict violation
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    violation=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['any_safety_floor_violation'])")
    assert_eq "safety floor one seed: cell_verdict" "fail" "$cell_verdict"
    assert_eq "safety floor one seed: any_safety_floor_violation" "True" "$violation"
}

# =========================================================================
# Test 6: All inconclusive (no scorable windows)
# =========================================================================

test_all_inconclusive() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "inconclusive" "null" "false" "true" "false" "false" "false" 0
    gen_verdict "$tmp/s2/verdict.json" "inconclusive" "null" "false" "true" "false" "false" "false" 0

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" 2>/dev/null

    local cell_verdict gc
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    gc=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['median_gap_closed'])")
    assert_eq "all inconclusive: cell_verdict" "inconclusive" "$cell_verdict"
    assert_eq "all inconclusive: median_gc=None" "None" "$gc"
}

# =========================================================================
# Test 7: Two seeds (minimum for aggregation)
#
# 2 seeds: gc = 0.30, 0.50
# Median of 2 values = (0.30 + 0.50) / 2 = 0.40 → strong_pass
# =========================================================================

test_two_seeds() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "strong_pass" 0.30
    gen_verdict "$tmp/s2/verdict.json" "strong_pass" 0.50

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" 2>/dev/null

    local cell_verdict gc n_seeds
    cell_verdict=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['cell_verdict'])")
    gc=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['median_gap_closed'])")
    n_seeds=$(python3 -c "import json; print(json.load(open('$tmp/out/aggregate.json'))['n_seeds'])")
    assert_eq "two seeds: cell_verdict" "strong_pass" "$cell_verdict"
    assert_eq "two seeds: median_gc=0.4" "0.4" "$gc"
    assert_eq "two seeds: n_seeds=2" "2" "$n_seeds"
}

# =========================================================================
# Test 8: Report file is generated
# =========================================================================

test_report_generated() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/s1" "$tmp/s2" "$tmp/s3" "$tmp/out"
    gen_verdict "$tmp/s1/verdict.json" "strong_pass" 0.40
    gen_verdict "$tmp/s2/verdict.json" "strong_pass" 0.45
    gen_verdict "$tmp/s3/verdict.json" "strong_pass" 0.50

    "$AGGREGATE" --output "$tmp/out" \
        "$tmp/s1/verdict.json" "$tmp/s2/verdict.json" "$tmp/s3/verdict.json" 2>/dev/null

    if [ -f "$tmp/out/aggregate_report.md" ]; then
        PASS=$((PASS + 1))
        TESTS+=("ok - report generated: aggregate_report.md exists")
    else
        FAIL=$((FAIL + 1))
        TESTS+=("FAIL - report generated: aggregate_report.md not found")
    fi

    if grep -q "STRONG PASS" "$tmp/out/aggregate_report.md"; then
        PASS=$((PASS + 1))
        TESTS+=("ok - report generated: contains STRONG PASS")
    else
        FAIL=$((FAIL + 1))
        TESTS+=("FAIL - report generated: does not contain STRONG PASS")
    fi
}

# =========================================================================
# Run all tests
# =========================================================================

echo "=== aggregate.sh test suite ==="
echo ""

test_all_strong_pass
test_bare_pass
test_one_seed_negative
test_cost_ceiling_one_seed
test_safety_floor_one_seed
test_all_inconclusive
test_two_seeds
test_report_generated

echo ""
for t in "${TESTS[@]}"; do
    echo "  $t"
done
echo ""
echo "$((PASS + FAIL)) tests: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
