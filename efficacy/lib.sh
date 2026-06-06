#!/usr/bin/env bash
# Shared shell functions for the efficacy harness.

set -euo pipefail

EFFICACY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$EFFICACY_DIR/.." && pwd)"

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

# --- Run ID ---

effi_run_id() {
    local arm="${1:?arm}" scenario="${2:?scenario}" seed="${3:?seed}"
    printf '%s-%s-s%s-%s' "$arm" "$scenario" "$seed" "$(date -u +%Y%m%dT%H%M%SZ)"
}
