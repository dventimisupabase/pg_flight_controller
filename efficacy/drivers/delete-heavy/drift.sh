#!/usr/bin/env bash
# Custom driver: delete_heavy drift.
# Class transition: delete_heavy -> oltp.
# Per cycle: 0 deletes, 100 updates on fix_delheavy.
# dupd/total > 0.30 with no deletes -> classifies as oltp after 3 sustained cycles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

DURATION="${EFFICACY_DURATION:-300}"
LOG_FILE="${1:?usage: drift.sh <log_file>}"
CYCLE_SLEEP=1

tx=0
start_epoch=$(effi_epoch_us)
start_s=$((start_epoch / 1000000))

while [ $(( $(date +%s) - start_s )) -lt "$DURATION" ]; do
    # UPDATE batch (100 rows) — no deletes
    t0=$(effi_epoch_us)
    effi_psql -c "UPDATE fix_delheavy SET data = repeat('y',100) WHERE id IN (SELECT id FROM fix_delheavy ORDER BY random() LIMIT 100);"
    t1=$(effi_epoch_us)
    tx=$((tx + 1))
    effi_driver_log "$LOG_FILE" "$tx" "$start_epoch" "$t0" "$t1"

    sleep "$CYCLE_SLEEP"
done

effi_log "delete_heavy drift: finished ($tx transactions over ${DURATION}s)"
