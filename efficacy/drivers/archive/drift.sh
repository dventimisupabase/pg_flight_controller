#!/usr/bin/env bash
# Custom driver: archive drift.
# Periodic purge: every PURGE_INTERVAL seconds, delete ~10% of rows and reload.
# During the purge window the table briefly classifies as delete_heavy or queue,
# then returns to archive once idle. Tests hysteresis against transient bursts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

DURATION="${EFFICACY_DURATION:-300}"
LOG_FILE="${1:?usage: drift.sh <log_file>}"
PURGE_INTERVAL=60
PURGE_PCT=10
TARGET_ROWS=200000

tx=0
start_epoch=$(effi_epoch_us)
start_s=$((start_epoch / 1000000))

while [ $(( $(date +%s) - start_s )) -lt "$DURATION" ]; do
    sleep "$PURGE_INTERVAL"

    # Check if we've exceeded the duration after sleeping
    if [ $(( $(date +%s) - start_s )) -ge "$DURATION" ]; then
        break
    fi

    effi_log "  archive drift: purging ~${PURGE_PCT}% of rows"

    # Batch delete ~10% of rows via TABLESAMPLE
    t0=$(effi_epoch_us)
    effi_psql -c "DELETE FROM fix_archive WHERE ctid IN (SELECT ctid FROM fix_archive TABLESAMPLE SYSTEM($PURGE_PCT));"
    t1=$(effi_epoch_us)
    tx=$((tx + 1))
    effi_driver_log "$LOG_FILE" "$tx" "$start_epoch" "$t0" "$t1"

    # Reload to maintain table size
    t0=$(effi_epoch_us)
    effi_psql -c "INSERT INTO fix_archive (code, label) SELECT 'CODE-' || g, 'Label ' || g FROM generate_series(1, (SELECT $TARGET_ROWS - count(*) FROM fix_archive)) g;"
    t1=$(effi_epoch_us)
    tx=$((tx + 1))
    effi_driver_log "$LOG_FILE" "$tx" "$start_epoch" "$t0" "$t1"
done

effi_log "archive drift: finished ($tx transactions over ${DURATION}s)"
