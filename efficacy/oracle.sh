#!/usr/bin/env bash
# Oracle computation (Phase 6, increment 4).
#
# Runs the workload 8 times — once per snap_sf grid value — then selects
# the per-window best p95 latency.  The oracle score for each window is
# the minimum p95 across all probes: the foreknowledge-optimal schedule.
#
# This is an approximation (EXP-001): the sweep is per-window-independent
# and uses a finite grid, so the true optimum may be lower.
#
#   DATABASE_URL="postgres://..." ./efficacy/oracle.sh
#
# Config via the same env vars as run.sh (except EFFICACY_ARM, which is
# forced to oracle-probe):
#
#   EFFICACY_FIXTURE          oltp
#   EFFICACY_SCENARIO         steady
#   EFFICACY_SEED             1
#   EFFICACY_DURATION         300
#   EFFICACY_SAMPLE_INTERVAL  30
#   EFFICACY_PGBENCH_CLIENTS  2
#   EFFICACY_PGBENCH_RATE     10
#
# Aggregate-only mode (skip probe execution, aggregate pre-existing results):
#
#   ORACLE_AGGREGATE_ONLY=1 ./efficacy/oracle.sh
#
# Contract for increment 5 (analysis):
#   - p95 is in microseconds (µs), per-window, windows numbered from 0
#   - window size = EFFICACY_SAMPLE_INTERVAL (must match across arms)
#   - empty windows (no transactions) produce no row

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config ---

FIXTURE="${EFFICACY_FIXTURE:-oltp}"
SCENARIO="${EFFICACY_SCENARIO:-steady}"
SEED="${EFFICACY_SEED:-1}"
SAMPLE_INTERVAL="${EFFICACY_SAMPLE_INTERVAL:-30}"
AGGREGATE_ONLY="${ORACLE_AGGREGATE_ONLY:-}"

SF_GRID=(0.005 0.01 0.02 0.05 0.10 0.20 0.30 0.50)

FIXTURE_SLUG="$(effi_fixture_slug "$FIXTURE")"
ORACLE_ID="oracle-${FIXTURE_SLUG}-${SCENARIO}-s${SEED}-$(date -u +%Y%m%dT%H%M%SZ)"
ORACLE_DIR="$EFFICACY_DIR/results/$ORACLE_ID"
mkdir -p "$ORACLE_DIR"

# =========================================================================
# Phase 1: Run one probe per grid value (or discover pre-existing probes)
# =========================================================================

PROBE_RUNS=()    # (sf run_id) pairs

if [ -n "$AGGREGATE_ONLY" ]; then
    effi_log "=== Oracle aggregate-only: discovering probes (fixture=$FIXTURE, scenario=$SCENARIO, seed=$SEED) ==="

    missing=()
    for sf in "${SF_GRID[@]}"; do
        if probe_dir=$(effi_find_oracle_probe "$FIXTURE" "$SCENARIO" "$SEED" "$sf" 2>/dev/null); then
            run_id=$(basename "$probe_dir")
            PROBE_RUNS+=("$sf $run_id")
            effi_log "  Found probe sf=$sf: $run_id"
        else
            missing+=("$sf")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        effi_log "ERROR: missing probes for sf values: ${missing[*]}"
        exit 1
    fi
else
    # --- Validate ---

    if [ -z "${DATABASE_URL:-}" ]; then
        effi_log "ERROR: DATABASE_URL is not set"
        exit 1
    fi

    effi_log "=== Oracle sweep: ${#SF_GRID[@]} probes (fixture=$FIXTURE, scenario=$SCENARIO, seed=$SEED) ==="

    for sf in "${SF_GRID[@]}"; do
        effi_log "--- Probe sf=$sf ---"

        EFFICACY_ARM="oracle-probe" \
        EFFICACY_ARM_SCRIPT="$EFFICACY_DIR/config/arm-oracle-probe.sql" \
        EFFICACY_ORACLE_SF="$sf" \
        EFFICACY_FIXTURE="$FIXTURE" \
        EFFICACY_SCENARIO="$SCENARIO" \
        EFFICACY_SEED="$SEED" \
            "$SCRIPT_DIR/run.sh" 2>&1 | tee "$ORACLE_DIR/probe-${sf}.log"

        RUN_DIR=$(sed -n 's/.*Results in \(.*\) ===.*/\1/p' "$ORACLE_DIR/probe-${sf}.log" | tail -1)
        if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
            effi_log "ERROR: no result directory found for probe sf=$sf"
            exit 1
        fi
        RUN_ID=$(basename "$RUN_DIR")

        PROBE_RUNS+=("$sf $RUN_ID")
        effi_log "Probe sf=$sf complete: $RUN_ID"
    done
fi

# =========================================================================
# Phase 2: Compute per-window p95 from each probe
# =========================================================================

effi_log "=== Computing per-window p95 across probes ==="

P95_SCRIPT="$SCRIPT_DIR/analysis/p95-from-log.sh"

# Header
echo "sf	window	p95_us	tx_count" > "$ORACLE_DIR/oracle_probes.csv"

for entry in "${PROBE_RUNS[@]}"; do
    sf=$(echo "$entry" | cut -d' ' -f1)
    run_id=$(echo "$entry" | cut -d' ' -f2)
    run_dir="$EFFICACY_DIR/results/$run_id"

    # Collect all pgbench log files from this probe run.
    log_files=()
    while IFS= read -r f; do
        log_files+=("$f")
    done < <(find "$run_dir" -name 'pgbench_log*' -type f 2>/dev/null)

    if [ ${#log_files[@]} -eq 0 ]; then
        effi_log "WARNING: no pgbench log files in $run_dir — skipping probe sf=$sf"
        continue
    fi

    # Compute per-window p95 and prepend the sf value.
    "$P95_SCRIPT" "$SAMPLE_INTERVAL" "${log_files[@]}" \
        | awk -v sf="$sf" -F'\t' '{ printf "%s\t%s\t%s\t%s\n", sf, $1, $2, $3 }' \
        >> "$ORACLE_DIR/oracle_probes.csv"
done

# =========================================================================
# Phase 3: Select per-window best (minimum p95) across probes
# =========================================================================

effi_log "=== Selecting per-window oracle (best p95) ==="

echo "window	best_sf	best_p95_us" > "$ORACLE_DIR/oracle_best.csv"

# Skip the header line, then for each window pick the row with the lowest p95.
tail -n +2 "$ORACLE_DIR/oracle_probes.csv" \
    | sort -t$'\t' -k2,2n -k3,3n \
    | awk -F'\t' '
    !seen[$2]++ {
        printf "%s\t%s\t%s\n", $2, $1, $3
    }' \
    >> "$ORACLE_DIR/oracle_best.csv"

# =========================================================================
# Phase 4: Write metadata
# =========================================================================

# Record which probe runs produced this oracle.
{
    echo "sf	run_id"
    for entry in "${PROBE_RUNS[@]}"; do
        sf=$(echo "$entry" | cut -d' ' -f1)
        run_id=$(echo "$entry" | cut -d' ' -f2)
        echo "$sf	$run_id"
    done
} > "$ORACLE_DIR/probe_runs.tsv"

cat > "$ORACLE_DIR/run_meta.json" <<EOJSON
{
  "oracle_id": "$ORACLE_ID",
  "fixture": "$FIXTURE",
  "scenario": "$SCENARIO",
  "seed": $SEED,
  "sf_grid": [$(IFS=,; echo "${SF_GRID[*]}")],
  "probe_count": ${#PROBE_RUNS[@]},
  "sample_interval_s": $SAMPLE_INTERVAL,
  "computed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON

effi_log "=== Oracle complete. Results in $ORACLE_DIR ==="
effi_log "  Probes: $ORACLE_DIR/oracle_probes.csv"
effi_log "  Best:   $ORACLE_DIR/oracle_best.csv"
ls -la "$ORACLE_DIR/"
