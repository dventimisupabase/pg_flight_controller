#!/usr/bin/env bash
# Custom driver: archive stationary.
# Near-silence — no writes. The 200k-row table sits idle.
# total = 0 < classify_floor(50) AND reltuples > classify_large(100000) -> archive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

DURATION="${EFFICACY_DURATION:-300}"
# LOG_FILE accepted but unused — no transactions to log.
# shellcheck disable=SC2034
LOG_FILE="${1:?usage: stationary.sh <log_file>}"

effi_log "archive stationary: sleeping for ${DURATION}s (no writes)"
sleep "$DURATION"
effi_log "archive stationary: finished"
