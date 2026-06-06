#!/usr/bin/env bash
# Compute per-window p95 latency from pgbench / custom-driver log files.
#
# Usage: p95-from-log.sh <window_seconds> <logfile>...
#
# Output (TSV, to stdout):
#   window   p95_us   tx_count
#
# Windows are numbered from 0, relative to the earliest transaction in the
# input.  pgbench --log format (columns used):
#   $3 = latency (microseconds)
#   $5 = epoch seconds of completion
# Custom-driver format (lib.sh effi_driver_log) uses the same column layout.

set -euo pipefail

WINDOW="${1:?usage: p95-from-log.sh <window_seconds> <logfile>...}"
shift

if [ $# -eq 0 ]; then
    echo "ERROR: no log files given" >&2
    exit 1
fi

# Pass 1: find the earliest epoch across all log files.
T_BASE=$(awk 'BEGIN { min = 999999999999 } { if ($5 < min) min = $5 } END { print min }' "$@")

# Pass 2: assign each transaction to a window and emit (window, latency).
awk -v window="$WINDOW" -v t_base="$T_BASE" '{
    w = int(($5 - t_base) / window)
    print w, $3
}' "$@" \
| sort -n -k1,1 -k2,2n \
| awk '
function emit() {
    idx = int(n * 0.95 + 0.5)
    if (idx < 1) idx = 1
    if (idx > n) idx = n
    printf "%d\t%d\t%d\n", cur, vals[idx], n
}
{
    if ($1 != cur && NR > 1) {
        emit()
        n = 0
    }
    cur = $1
    n++
    vals[n] = $2
}
END { if (n > 0) emit() }
'
