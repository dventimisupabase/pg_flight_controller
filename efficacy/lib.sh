#!/usr/bin/env bash
# Shared shell functions for the efficacy harness.

set -euo pipefail

EFFICACY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$EFFICACY_DIR/.." && pwd)"
export PROJECT_ROOT

# --- Logging ---

effi_log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# --- Prerequisites ---

effi_require() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        effi_log "ERROR: required command not found: $cmd"
        exit 1
    fi
}

# --- Database ---

effi_psql() {
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -X -q "$@"
}

effi_psql_file() {
    effi_psql -f "$1" "${@:2}"
}

# --- Fixture cleanup ---

effi_drop_stale_fixtures() {
    effi_psql -c "DO \$\$ BEGIN
      EXECUTE (SELECT coalesce(string_agg('DROP TABLE IF EXISTS ' || quote_ident(tablename) || ' CASCADE', '; '), 'SELECT 1')
               FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'fix_%');
    END \$\$;"
}

# --- Custom driver logging ---

effi_epoch_us() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=gettimeofday -e 'my ($s,$us)=gettimeofday; print $s*1000000+$us'
    else
        echo "$(date +%s)000000"
    fi
}

effi_driver_log() {
    local log_file="$1" tx_no="$2" t0="$4" t1="$5"
    local latency_us=$((t1 - t0))
    local epoch_s=$((t1 / 1000000))
    local epoch_frac_us=$((t1 % 1000000))
    printf '0 %d %d 0 %d %d 0\n' "$tx_no" "$latency_us" "$epoch_s" "$epoch_frac_us" >> "$log_file"
}

# --- Run ID ---

effi_run_id() {
    local arm="${1:?arm}" scenario="${2:?scenario}" seed="${3:?seed}"
    printf '%s-%s-s%s-%s' "$arm" "$scenario" "$seed" "$(date -u +%Y%m%dT%H%M%SZ)"
}
