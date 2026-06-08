#!/usr/bin/env bash
# Efficacy harness (Phase 6, increment 2).
#
# Runs a single (arm, fixture, scenario, seed) trial against a remote Supabase project.
# Requires DATABASE_URL pointing to the target project.
#
#   DATABASE_URL="postgres://..." ./efficacy/run.sh
#
# Use the direct/session connection (port 5432), not the transaction pooler
# (port 6543) — pgbench and session-level operations require session mode.
#
# Prerequisites:
#   - pg_cron must be installed on the target database (CREATE EXTENSION pg_cron).
#     pgfc requires pg_cron but does not install it — that's the operator's
#     responsibility, matching the pattern established by pg_flight_recorder.
#
# Config via env vars (defaults are the smoke config):
#
#   EFFICACY_ARM              defaults
#   EFFICACY_FIXTURE          oltp
#   EFFICACY_SCENARIO         steady
#   EFFICACY_SEED             1
#   EFFICACY_PRELOAD_ROWS     (per-fixture default; override with caution)
#   EFFICACY_DURATION         300       (seconds; used for pgfc-active arm)
#   EFFICACY_STATIC_DURATION  900       (seconds; used for static arms)
#   EFFICACY_SAMPLE_INTERVAL  30        (seconds)
#   EFFICACY_PGBENCH_CLIENTS  2
#   EFFICACY_PGBENCH_RATE     10        (tps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config (smoke defaults) ---

ARM="${EFFICACY_ARM:-defaults}"
FIXTURE="${EFFICACY_FIXTURE:-oltp}"
SCENARIO="${EFFICACY_SCENARIO:-steady}"
SEED="${EFFICACY_SEED:-1}"
FULL_DURATION="${EFFICACY_DURATION:-300}"
STATIC_DURATION="${EFFICACY_STATIC_DURATION:-900}"
SAMPLE_INTERVAL="${EFFICACY_SAMPLE_INTERVAL:-30}"
PGBENCH_CLIENTS="${EFFICACY_PGBENCH_CLIENTS:-2}"
PGBENCH_RATE="${EFFICACY_PGBENCH_RATE:-10}"

# Only pgfc-active needs the full duration (governor cadence: observe 60s,
# control 240s, classification hysteresis 720s, min_interval 3600s).
# Static arms just need enough time for the metric to stabilize.
if [ "$ARM" = "pgfc-active" ]; then
    DURATION="$FULL_DURATION"
else
    DURATION="${STATIC_DURATION}"
fi

# Per-fixture preload defaults (Phase 3 specs).
case "$FIXTURE" in
    append_only)  DEFAULT_PRELOAD=0      ;;
    queue)        DEFAULT_PRELOAD=0      ;;
    delete_heavy) DEFAULT_PRELOAD=5000   ;;
    oltp)         DEFAULT_PRELOAD=10000  ;;
    mixed)        DEFAULT_PRELOAD=5000   ;;
    archive)      DEFAULT_PRELOAD=200000 ;;
    *) effi_log "ERROR: unknown fixture: $FIXTURE"; exit 1 ;;
esac
PRELOAD_ROWS="${EFFICACY_PRELOAD_ROWS:-$DEFAULT_PRELOAD}"

if [ "$FIXTURE" = "archive" ] && [ "$PRELOAD_ROWS" -lt 100001 ]; then
    effi_log "WARNING: archive fixture requires preload > 100000 for classification (reltuples > classify_large). Got $PRELOAD_ROWS."
fi

# Map fixture name (underscores) to file path component (hyphens).
FIXTURE_SLUG="${FIXTURE//_/-}"

RUN_ID="$(effi_run_id "$ARM" "$FIXTURE" "$SCENARIO" "$SEED")"
RESULTS_DIR="$EFFICACY_DIR/results/$RUN_ID"

# =========================================================================
# Stage 1: Validate
# =========================================================================

effi_log "=== Stage 1: Validate ==="
effi_log "  fixture=$FIXTURE  arm=$ARM  scenario=$SCENARIO  seed=$SEED"

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
    || { effi_log "ERROR: pg_cron extension not found — run: CREATE EXTENSION pg_cron;"; exit 1; }
effi_log "pg_cron OK"

# Validate fixture file exists
FIXTURE_FILE="$EFFICACY_DIR/config/fixtures/${FIXTURE_SLUG}.sql"
if [ ! -f "$FIXTURE_FILE" ]; then
    effi_log "ERROR: fixture file not found: $FIXTURE_FILE"
    exit 1
fi

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

effi_log "Resetting govern telemetry (trial isolation)..."
effi_psql <<'SQL'
TRUNCATE
  pgfc_govern.action_history,
  pgfc_govern.tick_log,
  pgfc_govern.decision_log,
  pgfc_govern.diagnostics,
  pgfc_govern.actuator_state,
  pgfc_govern.relation_estimate,
  pgfc_govern.relation_class,
  pgfc_govern.policy_history,
  pgfc_govern.governor_state,
  pgfc_govern.state_transitions
CASCADE;
SQL

effi_log "Dropping stale fixture tables..."
effi_drop_stale_fixtures

effi_log "Creating fixture: $FIXTURE (preload=$PRELOAD_ROWS rows)..."
effi_psql_file "$FIXTURE_FILE" -v rows="$PRELOAD_ROWS"

effi_log "Creating efficacy_metrics table..."
effi_psql_file "$EFFICACY_DIR/sampler/create-metrics-table.sql"

# =========================================================================
# Stage 3: Arm setup
# =========================================================================

effi_log "=== Stage 3: Arm setup (arm=$ARM) ==="

ARM_SCRIPT="${EFFICACY_ARM_SCRIPT:-$EFFICACY_DIR/config/arm-${ARM}.sql}"
if [ ! -f "$ARM_SCRIPT" ]; then
    effi_log "ERROR: arm config not found: $ARM_SCRIPT"
    exit 1
fi
effi_psql_file "$ARM_SCRIPT" -v fixture="$FIXTURE" -v sf="${EFFICACY_ORACLE_SF:-0}"

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

effi_log "=== Stage 5: Drive workload (fixture=$FIXTURE, duration=${DURATION}s) ==="

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

        psql_args=(-c "SELECT pgfc_govern.observe_tick();")

        if [ $((tick_count % 4)) -eq 0 ]; then
            psql_args+=(-c "SELECT pgfc_govern.control_tick();")
        fi

        psql_args+=(-f "$EFFICACY_DIR/sampler/sample.sql"
            -v arm="$ARM" -v scenario="$SCENARIO" -v seed="$SEED")

        effi_psql "${psql_args[@]}" 2>/dev/null || true

        if [ $((tick_count % 4)) -eq 0 ]; then
            effi_log "  control_tick at t+${elapsed}s"
        fi
        effi_log "  sampled at t+${elapsed}s"
    done
) &
SAMPLER_PID=$!

# --- Driver dispatch ---

effi_run_pgbench_driver() {
    local driver_dir="$EFFICACY_DIR/drivers/$FIXTURE_SLUG"
    local pgbench_args=()

    case "${FIXTURE}_${SCENARIO}" in
        append_only_steady)
            pgbench_args+=(-f "$driver_dir/stationary.sql@1")
            ;;
        append_only_drift)
            pgbench_args+=(-f "$driver_dir/stationary.sql@1")
            ;;
        queue_steady)
            pgbench_args+=(-f "$driver_dir/insert.sql@100" -f "$driver_dir/delete.sql@95")
            ;;
        queue_drift)
            pgbench_args+=(-f "$driver_dir/insert.sql@200" -f "$driver_dir/delete.sql@190")
            ;;
        oltp_steady)
            pgbench_args+=(-f "$driver_dir/insert.sql@10" -f "$driver_dir/update.sql@150" -f "$driver_dir/delete.sql@5")
            ;;
        oltp_drift)
            pgbench_args+=(-f "$driver_dir/insert.sql@10" -f "$driver_dir/update.sql@450" -f "$driver_dir/delete.sql@5")
            ;;
        mixed_steady)
            pgbench_args+=(-f "$driver_dir/insert.sql@40" -f "$driver_dir/update.sql@20" -f "$driver_dir/delete.sql@15")
            ;;
        mixed_drift)
            pgbench_args+=(-f "$driver_dir/insert.sql@50" -f "$driver_dir/update.sql@20" -f "$driver_dir/delete.sql@45")
            ;;
        *)
            effi_log "ERROR: no pgbench driver for ${FIXTURE}_${SCENARIO}"
            exit 1
            ;;
    esac

    effi_log "Starting pgbench (clients=$PGBENCH_CLIENTS, rate=$PGBENCH_RATE tps)..."
    pgbench "$DATABASE_URL" \
        "${pgbench_args[@]}" \
        --no-vacuum \
        -c "$PGBENCH_CLIENTS" \
        -j "$PGBENCH_CLIENTS" \
        -T "$DURATION" \
        -R "$PGBENCH_RATE" \
        -D rows="$PRELOAD_ROWS" \
        --log \
        --log-prefix="$RESULTS_DIR/pgbench_log" \
        --progress=30 \
        2>&1 | tee "$RESULTS_DIR/pgbench_stdout.txt"
}

effi_run_custom_driver() {
    local driver_dir="$EFFICACY_DIR/drivers/$FIXTURE_SLUG"
    local script

    case "$SCENARIO" in
        steady) script="$driver_dir/stationary.sh" ;;
        drift)  script="$driver_dir/drift.sh" ;;
        *)
            effi_log "ERROR: unknown scenario for custom driver: $SCENARIO"
            exit 1
            ;;
    esac

    if [ ! -x "$script" ]; then
        effi_log "ERROR: driver script not found or not executable: $script"
        exit 1
    fi

    effi_log "Starting custom driver: $script"
    "$script" "$RESULTS_DIR/pgbench_log"
}

case "$FIXTURE" in
    append_only|queue|oltp|mixed)
        effi_run_pgbench_driver
        ;;
    delete_heavy|archive)
        effi_run_custom_driver
        ;;
esac

effi_log "Driver finished, waiting for sampler..."
wait "$SAMPLER_PID" 2>/dev/null || true

# Final sample after driver stops
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

# Fixture reloptions (records what expert-static/pgfc-active actually applied)
effi_psql -c "\copy (SELECT relname, reloptions FROM pg_class WHERE relname LIKE 'fix_%' AND relnamespace = 'public'::regnamespace ORDER BY relname) TO STDOUT CSV HEADER" \
    > "$RESULTS_DIR/fixture_reloptions.csv"

# Run metadata
cat > "$RESULTS_DIR/run_meta.json" <<EOJSON
{
  "run_id": "$RUN_ID",
  "arm": "$ARM",
  "fixture": "$FIXTURE",
  "scenario": "$SCENARIO",
  "seed": $SEED,
  "preload_rows": $PRELOAD_ROWS,
  "duration_s": $DURATION,
  "sample_interval_s": $SAMPLE_INTERVAL,
  "pgbench_clients": $PGBENCH_CLIENTS,
  "pgbench_rate": $PGBENCH_RATE,
  "oracle_sf": ${EFFICACY_ORACLE_SF:-null},
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "autovacuum_freeze_max_age": $(effi_psql -tA -c "SHOW autovacuum_freeze_max_age")
}
EOJSON

effi_log "=== Done. Results in $RESULTS_DIR ==="
ls -la "$RESULTS_DIR/"
