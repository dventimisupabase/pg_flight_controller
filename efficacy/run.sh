#!/usr/bin/env bash
# Efficacy harness — scaffold (Phase 6, increment 1).
#
# Runs a single (arm, scenario, seed) trial against a remote Supabase project.
# Requires DATABASE_URL pointing to the target project.
#
#   DATABASE_URL="postgres://..." ./efficacy/run.sh
#
# Use the direct/session connection (port 5432), not the transaction pooler
# (port 6543) — pgbench and session-level operations require session mode.
#
# Config via env vars (defaults are the smoke config):
#
#   EFFICACY_ARM              defaults
#   EFFICACY_SCENARIO         steady
#   EFFICACY_SEED             1
#   EFFICACY_PRELOAD_ROWS     1000
#   EFFICACY_DURATION         300       (seconds)
#   EFFICACY_SAMPLE_INTERVAL  30        (seconds)
#   EFFICACY_PGBENCH_CLIENTS  2
#   EFFICACY_PGBENCH_RATE     10        (tps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config (smoke defaults) ---

ARM="${EFFICACY_ARM:-defaults}"
SCENARIO="${EFFICACY_SCENARIO:-steady}"
SEED="${EFFICACY_SEED:-1}"
PRELOAD_ROWS="${EFFICACY_PRELOAD_ROWS:-1000}"
DURATION="${EFFICACY_DURATION:-300}"
SAMPLE_INTERVAL="${EFFICACY_SAMPLE_INTERVAL:-30}"
PGBENCH_CLIENTS="${EFFICACY_PGBENCH_CLIENTS:-2}"
PGBENCH_RATE="${EFFICACY_PGBENCH_RATE:-10}"

RUN_ID="$(effi_run_id "$ARM" "$SCENARIO" "$SEED")"
RESULTS_DIR="$EFFICACY_DIR/results/$RUN_ID"

# =========================================================================
# Stage 1: Validate
# =========================================================================

effi_log "=== Stage 1: Validate ==="

if [ -z "${DATABASE_URL:-}" ]; then
    effi_log "ERROR: DATABASE_URL is not set"
    exit 1
fi

effi_require psql
effi_require pgbench

effi_log "Testing connection..."
effi_psql -c "SELECT version();" >/dev/null
effi_log "Connection OK"

effi_log "Checking pg_cron..."
effi_psql -c "SELECT 1 FROM pg_extension WHERE extname = 'pg_cron';" | grep -q 1 \
    || { effi_log "ERROR: pg_cron extension not found"; exit 1; }
effi_log "pg_cron OK"

# =========================================================================
# Stage 2: Init — install extensions + create fixtures
# =========================================================================

effi_log "=== Stage 2: Init ==="

effi_log "Installing pgfc_observe (x2 for idempotency)..."
effi_psql_file "$PROJECT_ROOT/pgfc_observe/install.sql"
effi_psql_file "$PROJECT_ROOT/pgfc_observe/install.sql"

effi_log "Installing pgfc_govern (x2 for idempotency)..."
effi_psql_file "$PROJECT_ROOT/pgfc_govern/install.sql"
effi_psql_file "$PROJECT_ROOT/pgfc_govern/install.sql"

effi_log "Creating fixtures (preload=$PRELOAD_ROWS rows)..."
effi_psql_file "$EFFICACY_DIR/config/fixtures.sql" -v rows="$PRELOAD_ROWS"

effi_log "Creating efficacy_metrics table..."
effi_psql_file "$EFFICACY_DIR/sampler/create-metrics-table.sql"

# =========================================================================
# Stage 3: Arm setup
# =========================================================================

effi_log "=== Stage 3: Arm setup (arm=$ARM) ==="

ARM_SCRIPT="$EFFICACY_DIR/config/arm-${ARM}.sql"
if [ ! -f "$ARM_SCRIPT" ]; then
    effi_log "ERROR: arm config not found: $ARM_SCRIPT"
    exit 1
fi
effi_psql_file "$ARM_SCRIPT"

# =========================================================================
# Stage 4: Baseline
# =========================================================================

effi_log "=== Stage 4: Baseline ==="

effi_log "Seeding first snapshot via observe_tick()..."
effi_psql -c "SELECT pgfc_govern.observe_tick();"

effi_log "Taking baseline sample..."
effi_psql_file "$EFFICACY_DIR/sampler/sample.sql" \
    -v arm="$ARM" -v scenario="$SCENARIO" -v seed="$SEED"

# =========================================================================
# Stage 5: Drive workload + sample metrics
# =========================================================================

effi_log "=== Stage 5: Drive workload (duration=${DURATION}s, clients=$PGBENCH_CLIENTS, rate=$PGBENCH_RATE tps) ==="

mkdir -p "$RESULTS_DIR"

# Background sampler: periodic metric snapshots + pgfc tick driving.
# In production, pg_cron drives observe_tick/control_tick autonomously (#113).
# Here we drive them explicitly so the smoke run populates pgfc telemetry
# tables and proves the full pipeline without depending on cron.
(
    elapsed=0
    tick_count=0
    while [ "$elapsed" -lt "$DURATION" ]; do
        sleep "$SAMPLE_INTERVAL"
        elapsed=$((elapsed + SAMPLE_INTERVAL))
        tick_count=$((tick_count + 1))

        # Drive the observe loop (production cadence: 1 min)
        effi_psql -c "SELECT pgfc_govern.observe_tick();" 2>/dev/null || true

        # Drive the control loop less frequently (production cadence: 5 min)
        if [ $((tick_count % 4)) -eq 0 ]; then
            effi_psql -c "SELECT pgfc_govern.control_tick();" 2>/dev/null || true
            effi_log "  control_tick at t+${elapsed}s"
        fi

        effi_psql_file "$EFFICACY_DIR/sampler/sample.sql" \
            -v arm="$ARM" -v scenario="$SCENARIO" -v seed="$SEED" 2>/dev/null || true
        effi_log "  sampled at t+${elapsed}s"
    done
) &
SAMPLER_PID=$!

# pgbench workload driver
effi_log "Starting pgbench..."
pgbench "$DATABASE_URL" \
    -f "$EFFICACY_DIR/drivers/oltp.sql" \
    -c "$PGBENCH_CLIENTS" \
    -j "$PGBENCH_CLIENTS" \
    -T "$DURATION" \
    -R "$PGBENCH_RATE" \
    -D rows="$PRELOAD_ROWS" \
    --log \
    --log-prefix="$RESULTS_DIR/pgbench_log" \
    --progress=30 \
    2>&1 | tee "$RESULTS_DIR/pgbench_stdout.txt"

effi_log "pgbench finished, waiting for sampler..."
wait "$SAMPLER_PID" 2>/dev/null || true

# Final sample after pgbench stops
effi_log "Taking final sample..."
effi_psql_file "$EFFICACY_DIR/sampler/sample.sql" \
    -v arm="$ARM" -v scenario="$SCENARIO" -v seed="$SEED"

# =========================================================================
# Stage 6: Collect
# =========================================================================

effi_log "=== Stage 6: Collect (results -> $RESULTS_DIR) ==="

# Efficacy metrics
effi_psql -c "\copy (SELECT * FROM efficacy_metrics WHERE arm = '$ARM' AND scenario = '$SCENARIO' AND seed = $SEED ORDER BY sample_id) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/efficacy_metrics.csv"

# pgfc telemetry
effi_psql -c "\copy (SELECT * FROM pgfc_govern.governor_status ORDER BY relname) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/governor_status.csv"

effi_psql -c "\copy (SELECT * FROM pgfc_govern.decision_log ORDER BY decision_id) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/decision_log.csv"

effi_psql -c "\copy (SELECT * FROM pgfc_govern.action_history ORDER BY action_id) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/action_history.csv"

effi_psql -c "\copy (SELECT * FROM pgfc_govern.tick_log ORDER BY tick_id) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/tick_log.csv"

effi_psql -c "\copy (SELECT * FROM pgfc_govern.relation_class ORDER BY relname) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/relation_class.csv"

effi_psql -c "\copy (SELECT * FROM pgfc_govern.relation_estimate ORDER BY relid) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/relation_estimate.csv"

# Run metadata
cat > "$RESULTS_DIR/run_meta.json" <<EOJSON
{
  "run_id": "$RUN_ID",
  "arm": "$ARM",
  "scenario": "$SCENARIO",
  "seed": $SEED,
  "preload_rows": $PRELOAD_ROWS,
  "duration_s": $DURATION,
  "sample_interval_s": $SAMPLE_INTERVAL,
  "pgbench_clients": $PGBENCH_CLIENTS,
  "pgbench_rate": $PGBENCH_RATE,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON

effi_log "=== Done. Results in $RESULTS_DIR ==="
ls -la "$RESULTS_DIR/"
