#!/usr/bin/env bash
# Tests for analyze.sh — synthetic known-answer inputs.
#
# Generates tiny pgbench logs and metrics files with predetermined p95 values,
# runs the analysis pipeline, and asserts the verdict.
#
# Usage: ./efficacy/analysis/test-analyze.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANALYZE="$SCRIPT_DIR/analyze.sh"

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

assert_contains() {
    local label="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -qF "$expected"; then
        PASS=$((PASS + 1))
        TESTS+=("ok - $label")
    else
        FAIL=$((FAIL + 1))
        TESTS+=("FAIL - $label (expected to contain '$expected')")
    fi
}

# =========================================================================
# Helper: generate a synthetic pgbench log for one arm.
#
# gen_pgbench_log <file> <t_base> <window_seconds> <n_windows> <latency_per_window...>
#
# Each window gets 20 transactions, all with the given latency (µs).
# This means p95 = that latency (since all values are equal).
# =========================================================================

gen_pgbench_log() {
    local file="$1" t_base="$2" window_s="$3" n_windows="$4"
    shift 4

    local tx_no=0
    for ((w=0; w < n_windows; w++)); do
        local latency="${1:-100000}"
        shift 2>/dev/null || true

        for ((t=0; t < 20; t++)); do
            tx_no=$((tx_no + 1))
            local epoch=$((t_base + w * window_s + t))
            printf '0 %d %d 0 %d 0 0\n' "$tx_no" "$latency" "$epoch"
        done
    done > "$file"
}

gen_run_meta() {
    local dir="$1" arm="$2" fixture="${3:-oltp}" scenario="${4:-steady}" seed="${5:-1}" interval="${6:-30}" freeze_max_age="${7:-}"
    local freeze_line=""
    if [ -n "$freeze_max_age" ]; then
        freeze_line=",
  \"autovacuum_freeze_max_age\": $freeze_max_age"
    fi
    cat > "$dir/run_meta.json" <<EOJSON
{
  "run_id": "${arm}-${scenario}-s${seed}-test",
  "arm": "$arm",
  "fixture": "$fixture",
  "scenario": "$scenario",
  "seed": $seed,
  "preload_rows": 10000,
  "duration_s": 300,
  "sample_interval_s": $interval,
  "pgbench_clients": 2,
  "pgbench_rate": 10,
  "started_at": "2026-06-06T00:00:00Z"${freeze_line}
}
EOJSON
}

gen_efficacy_metrics() {
    local file="$1" arm="$2" n_samples="$3" av_count="${4:-5}" pgfc_applied="${5:-0}" max_xid_age="${6:-100}"
    {
        echo "sample_id,sampled_at,arm,scenario,seed,relname,dead_frac,rel_size,xid_age,mxid_age,av_count,av_last,pgfc_applied"
        for ((i=1; i <= n_samples; i++)); do
            echo "$i,2026-06-06T00:0${i}:00Z,$arm,steady,1,fix_oltp,0.05,884736,$max_xid_age,0,$av_count,2026-06-06T00:0${i}:00Z,$pgfc_applied"
        done
    } > "$file"
}

gen_oracle_best() {
    local file="$1"
    shift
    {
        echo "window	best_sf	best_p95_us"
        local w=0
        for p95 in "$@"; do
            printf '%d\t0.10\t%d\n' "$w" "$p95"
            w=$((w + 1))
        done
    } > "$file"
}


# =========================================================================
# Test 1: Strong pass — gap_closed = 0.5
#
# 10 windows, window_s=30. Warm-up discards first 2 (20%).
# Windows 2-9 all have:
#   expert_p95 = 200000, pgfc_p95 = 150000, oracle_p95 = 100000
#   gap_closed = (200000-150000)/(200000-100000) = 0.5 → strong pass
# =========================================================================

test_strong_pass() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000
    local window_s=30

    # 10 windows, all same latencies (warm-up windows 0,1 are discarded)
    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    # Defaults: 300000 µs p95
    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults" "oltp" "steady" 1 "$window_s"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10 5 0

    # Expert-static: 200000 µs p95
    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static" "oltp" "steady" 1 "$window_s"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10 8 0

    # pgfc-active: 150000 µs p95
    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        150000 150000 150000 150000 150000 150000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active" "oltp" "steady" 1 "$window_s"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10 8 3

    # Oracle: 100000 µs p95
    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle" "oltp" "steady" 1 "$window_s"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "strong pass: verdict" "strong_pass" "$verdict"

    local gc
    gc=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['median_gap_closed'])")
    assert_eq "strong pass: gap_closed=0.5" "0.5" "$gc"
}

# =========================================================================
# Test 2: Bare pass — gap_closed = 0.0
#
# pgfc matches expert-static (both 200000), oracle at 100000.
# gap_closed = 0 / 100000 = 0.0 → pass
# =========================================================================

test_bare_pass() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "bare pass: verdict" "pass" "$verdict"

    local gc
    gc=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['median_gap_closed'])")
    assert_eq "bare pass: gap_closed=0.0" "0.0" "$gc"
}

# =========================================================================
# Test 3: Fail — gap_closed < 0 (pgfc worse than expert)
#
# expert=200000, pgfc=250000, oracle=100000
# gap_closed = (200000-250000)/(200000-100000) = -0.5 → fail
# =========================================================================

test_fail_negative_gc() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        250000 250000 250000 250000 250000 250000 250000 250000 250000 250000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "fail (pgfc worse): verdict" "fail" "$verdict"
}

# =========================================================================
# Test 4: Denominator guard — windows where expert ≤ oracle are dropped
#
# 10 windows. Windows 2,3 have expert=100000, oracle=100000 (denom=0).
# Windows 4,5 have expert=90000, oracle=100000 (denom<0).
# Remaining graded windows (6-9): expert=200000, pgfc=150000, oracle=100000 → gc=0.5
# =========================================================================

test_denom_guard() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    # Windows 0-1: warmup (discarded). 2-3: denom=0. 4-5: denom<0. 6-9: normal.
    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 100000 100000 90000 90000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        150000 150000 100000 100000 80000 80000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict gc dropped
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    gc=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['median_gap_closed'])")
    dropped=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['windows_dropped_denom'])")

    assert_eq "denom guard: verdict" "strong_pass" "$verdict"
    assert_eq "denom guard: gap_closed=0.5" "0.5" "$gc"
    assert_eq "denom guard: 4 windows dropped" "4" "$dropped"
}

# =========================================================================
# Test 5: Warmup discard — first 20% of windows are excluded
#
# 10 windows. Windows 0,1 (warmup) have bad pgfc latency (fail-level).
# Windows 2-9 have strong-pass latency. Verdict should be strong_pass.
# =========================================================================

test_warmup_discard() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    # Windows 0,1: pgfc worse than expert (500000). Windows 2-9: pgfc strong (150000).
    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        500000 500000 150000 150000 150000 150000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "warmup discard: verdict is strong_pass (bad warmup windows excluded)" "strong_pass" "$verdict"
}

# =========================================================================
# Test 6: Cost ceiling breach — pgfc_applied > daily_mutation_budget
# =========================================================================

test_cost_ceiling_breach() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10 5 0

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10 8 0

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        150000 150000 150000 150000 150000 150000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    # pgfc_applied=600 exceeds daily_mutation_budget=500
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10 8 600

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "cost ceiling breach: verdict is fail" "fail" "$verdict"

    local breach
    breach=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['cost_ceiling_breach'])")
    assert_eq "cost ceiling breach: flag is True" "True" "$breach"
}

# =========================================================================
# Test 7: Autovacuum frequency ceiling — pgfc av_count > 2x defaults
# =========================================================================

test_av_frequency_ceiling() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10 5 0

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        150000 150000 150000 150000 150000 150000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    # av_count=15, defaults=5 → 3x → breach
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10 15 3

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "av frequency ceiling: verdict is fail" "fail" "$verdict"
}

# =========================================================================
# Test 8: Safety floor violation under accelerated config
#
# freeze_max_age=10000 (accelerated), worst xid_age=50000 → fail
# Even though gap_closed would be strong_pass, safety overrides.
# =========================================================================

test_safety_floor_accelerated() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults" "oltp" "steady" 1 "$window_s" 10000
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10 5 0 50000

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static" "oltp" "steady" 1 "$window_s" 10000
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10 8 0 50000

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        150000 150000 150000 150000 150000 150000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active" "oltp" "steady" 1 "$window_s" 10000
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10 8 3 50000

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle" "oltp" "steady" 1 "$window_s" 10000

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "safety floor (accelerated): verdict is fail" "fail" "$verdict"

    local evaluated
    evaluated=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['safety_floor_evaluated'])")
    assert_eq "safety floor (accelerated): evaluated is True" "True" "$evaluated"
}

# =========================================================================
# Test 9: Safety floor not evaluated (no freeze_max_age in run_meta)
#
# Without autovacuum_freeze_max_age, verdict should not claim safety holds.
# With gc=0.5 and no gate breach, verdict should be strong_pass but
# safety_floor_evaluated should be False.
# =========================================================================

test_safety_floor_not_evaluated() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        150000 150000 150000 150000 150000 150000 150000 150000 150000 150000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local evaluated
    evaluated=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['safety_floor_evaluated'])")
    assert_eq "safety floor (no metadata): evaluated is False" "False" "$evaluated"

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "safety floor (no metadata): verdict is strong_pass (gate skipped)" "strong_pass" "$verdict"
}

# =========================================================================
# Test 10: Boundary — gap_closed exactly 0.25 → strong_pass
#
# expert=200000, oracle=100000 (denom=100000)
# pgfc=175000 → gc = (200000-175000)/100000 = 0.25 → strong_pass
# =========================================================================

test_boundary_strong_pass() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        175000 175000 175000 175000 175000 175000 175000 175000 175000 175000
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict gc
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    gc=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['median_gap_closed'])")
    assert_eq "boundary 0.25: verdict is strong_pass" "strong_pass" "$verdict"
    assert_eq "boundary 0.25: gap_closed=0.25" "0.25" "$gc"
}

# =========================================================================
# Test 11: Boundary — tiny negative gap_closed → fail
#
# expert=200000, oracle=100000 (denom=100000)
# pgfc=200001 → gc = (200000-200001)/100000 = -0.00001 → fail
# =========================================================================

test_boundary_tiny_negative() {
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN

    local t_base=1000000 window_s=30

    mkdir -p "$tmp/defaults" "$tmp/expert" "$tmp/pgfc" "$tmp/oracle" "$tmp/out"

    gen_pgbench_log "$tmp/defaults/pgbench_log.0" "$t_base" "$window_s" 10 \
        300000 300000 300000 300000 300000 300000 300000 300000 300000 300000
    gen_run_meta "$tmp/defaults" "defaults"
    gen_efficacy_metrics "$tmp/defaults/efficacy_metrics.csv" "defaults" 10

    gen_pgbench_log "$tmp/expert/pgbench_log.0" "$t_base" "$window_s" 10 \
        200000 200000 200000 200000 200000 200000 200000 200000 200000 200000
    gen_run_meta "$tmp/expert" "expert-static"
    gen_efficacy_metrics "$tmp/expert/efficacy_metrics.csv" "expert-static" 10

    gen_pgbench_log "$tmp/pgfc/pgbench_log.0" "$t_base" "$window_s" 10 \
        200001 200001 200001 200001 200001 200001 200001 200001 200001 200001
    gen_run_meta "$tmp/pgfc" "pgfc-active"
    gen_efficacy_metrics "$tmp/pgfc/efficacy_metrics.csv" "pgfc-active" 10

    gen_oracle_best "$tmp/oracle/oracle_best.csv" \
        100000 100000 100000 100000 100000 100000 100000 100000 100000 100000
    gen_run_meta "$tmp/oracle" "oracle"

    "$ANALYZE" \
        --defaults "$tmp/defaults" \
        --expert-static "$tmp/expert" \
        --pgfc-active "$tmp/pgfc" \
        --oracle "$tmp/oracle" \
        --output "$tmp/out" 2>/dev/null

    local verdict
    verdict=$(python3 -c "import json,sys; print(json.load(open('$tmp/out/verdict.json'))['verdict'])")
    assert_eq "boundary tiny negative: verdict is fail" "fail" "$verdict"
}

# =========================================================================
# Run all tests
# =========================================================================

echo "=== analyze.sh test suite ==="
echo ""

test_strong_pass
test_bare_pass
test_fail_negative_gc
test_denom_guard
test_warmup_discard
test_cost_ceiling_breach
test_av_frequency_ceiling
test_safety_floor_accelerated
test_safety_floor_not_evaluated
test_boundary_strong_pass
test_boundary_tiny_negative

echo ""
for t in "${TESTS[@]}"; do
    echo "  $t"
done
echo ""
echo "$((PASS + FAIL)) tests: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
