#!/usr/bin/env bash
# Custom driver: delete_heavy stationary.
# Per cycle: DELETE 150 rows + INSERT 30 rows from a preloaded pool.
# Periodic refill when live count drops below threshold (FIX-001).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

DURATION="${EFFICACY_DURATION:-300}"
LOG_FILE="${1:?usage: stationary.sh <log_file>}"
CYCLE_SLEEP=1
REFILL_THRESHOLD=500
REFILL_BATCH=2000

tx=0
start_epoch=$(effi_epoch_us)
start_s=$((start_epoch / 1000000))

while [ $(( $(date +%s) - start_s )) -lt "$DURATION" ]; do
    # DELETE batch (up to 150 rows)
    t0=$(effi_epoch_us)
    effi_psql -c "DELETE FROM fix_delheavy WHERE id IN (SELECT id FROM fix_delheavy LIMIT 150);"
    t1=$(effi_epoch_us)
    tx=$((tx + 1))
    effi_driver_log "$LOG_FILE" "$tx" "$start_epoch" "$t0" "$t1"

    # INSERT batch (30 rows)
    t0=$(effi_epoch_us)
    effi_psql -c "INSERT INTO fix_delheavy (user_id, data, expires) SELECT (random()*1000)::int, repeat('x',100), now()+(random()*interval '30 days') FROM generate_series(1,30);"
    t1=$(effi_epoch_us)
    tx=$((tx + 1))
    effi_driver_log "$LOG_FILE" "$tx" "$start_epoch" "$t0" "$t1"

    # Periodic refill when pool runs low
    live=$(effi_psql -t -c "SELECT count(*) FROM fix_delheavy;" | tr -d ' ')
    if [ "${live:-0}" -lt "$REFILL_THRESHOLD" ]; then
        effi_log "  delete_heavy refill: live=$live < $REFILL_THRESHOLD, inserting $REFILL_BATCH rows"
        t0=$(effi_epoch_us)
        effi_psql -c "INSERT INTO fix_delheavy (user_id, data, expires) SELECT (random()*1000)::int, repeat('x',100), now()+(random()*interval '30 days') FROM generate_series(1,$REFILL_BATCH);"
        t1=$(effi_epoch_us)
        tx=$((tx + 1))
        effi_driver_log "$LOG_FILE" "$tx" "$start_epoch" "$t0" "$t1"
    fi

    sleep "$CYCLE_SLEEP"
done

effi_log "delete_heavy stationary: finished ($tx transactions over ${DURATION}s)"
