#!/usr/bin/env bash
# Parallel e2e campaign lifecycle.
#
# Fans the campaign matrix across N Supabase projects by seed, using GNU
# Parallel for job management.  Each worker runs e2e.sh with a single seed;
# after all workers finish, runs analysis (Phase 2/3) on the combined results.
#
#   E2E_ORG_ID=<org> E2E_WORKERS=3 ./efficacy/e2e-parallel.sh
#
# Config via env vars:
#
#   E2E_WORKERS          1           number of parallel workers (1 = delegate to e2e.sh)
#   E2E_ORG_ID           (required)  Supabase org
#   E2E_REGION           us-east-1
#   E2E_SIZE             micro
#   E2E_SUPABASE_DOMAIN  supabase.green
#   E2E_MAX_RETRIES      3
#   E2E_RETRY_DELAY      10
#   E2E_READINESS_TIMEOUT 300
#
#   Campaign pass-through:
#   CAMPAIGN_PROFILE     profiles/smoke.env
#   CAMPAIGN_ARMS        "defaults expert-static pgfc-active"
#   CAMPAIGN_FIXTURES    "oltp"
#   CAMPAIGN_SCENARIOS   "steady drift"
#   CAMPAIGN_SEEDS       "1 2 3"
#   CAMPAIGN_SKIP_ORACLE
#   CAMPAIGN_DRY_RUN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config ---

N_WORKERS="${E2E_WORKERS:-1}"
read -ra SEEDS <<< "${CAMPAIGN_SEEDS:-1 2 3}"
N_SEEDS=${#SEEDS[@]}
TS="$(date -u +%Y%m%dT%H%M%SZ)"

# --- Single-worker fast path ---

if [ "$N_WORKERS" -le 1 ]; then
    exec "$SCRIPT_DIR/e2e.sh"
fi

# --- Preflight ---

effi_log "=== Parallel E2E Campaign (workers=$N_WORKERS, seeds=${SEEDS[*]}) ==="

: "${E2E_ORG_ID:?E2E_ORG_ID is required (run: supabase orgs list)}"

effi_require parallel
effi_require supabase
effi_require psql
effi_require pgbench
effi_require jq
effi_require openssl

if [ "$N_WORKERS" -gt "$N_SEEDS" ]; then
    effi_log "WARNING: E2E_WORKERS ($N_WORKERS) > number of seeds ($N_SEEDS); capping at $N_SEEDS"
    N_WORKERS="$N_SEEDS"
fi

effi_log "  Workers:   $N_WORKERS"
effi_log "  Seeds:     ${SEEDS[*]}"
effi_log "  Org:       $E2E_ORG_ID"
effi_log "  Region:    ${E2E_REGION:-us-east-1}"

# --- Dry-run fast path ---

if [ -n "${CAMPAIGN_DRY_RUN:-}" ]; then
    effi_log "=== Dry run: forwarding each seed to e2e.sh ==="
    for seed in "${SEEDS[@]}"; do
        effi_log "--- Worker for seed $seed ---"
        CAMPAIGN_SEEDS="$seed" CAMPAIGN_SKIP_ANALYZE=1 "$SCRIPT_DIR/e2e.sh"
    done
    effi_log "=== Running analysis (dry-run) ==="
    CAMPAIGN_ANALYZE_ONLY=1 "$SCRIPT_DIR/campaign.sh"
    exit 0
fi

# =========================================================================
# Phase 1: Launch workers via GNU Parallel
# =========================================================================

effi_log "=== Phase 1: Launching $N_WORKERS workers ==="

RESULTS_DIR="$EFFICACY_DIR/results"
JOBLOG="$RESULTS_DIR/parallel-joblog-${TS}.txt"
WORKER_LOGS="$RESULTS_DIR/parallel-logs-${TS}"
mkdir -p "$RESULTS_DIR" "$WORKER_LOGS"

export E2E_ORG_ID
export CAMPAIGN_SKIP_ANALYZE=1

printf '%s\n' "${SEEDS[@]}" | \
    parallel \
        -j "$N_WORKERS" \
        --delay 5 \
        --halt never \
        --joblog "$JOBLOG" \
        --tag \
        env \
            CAMPAIGN_SEEDS={} \
            CAMPAIGN_SKIP_ANALYZE=1 \
            E2E_WORKER_ID='{#}' \
            "E2E_PROJECT_NAME=pgfc-efficacy-${TS}-w{#}" \
            "$SCRIPT_DIR/e2e.sh" \
        '>' "$WORKER_LOGS/worker-{#}.log" '2>&1' \
    || true

# =========================================================================
# Phase 2: Inspect results
# =========================================================================

effi_log "=== Phase 2: Worker results ==="

n_succeeded=0
n_failed=0

if [ -f "$JOBLOG" ]; then
    while IFS=$'\t' read -r seq _host _starttime jobruntime _send _receive exitval _signal command; do
        [ "$seq" = "Seq" ] && continue
        if [ "$exitval" -eq 0 ]; then
            effi_log "  Worker $seq (seed $(echo "$command" | grep -oE 'CAMPAIGN_SEEDS=[^ ]+' | cut -d= -f2)): OK (${jobruntime}s)"
            n_succeeded=$((n_succeeded + 1))
        else
            effi_log "  Worker $seq (seed $(echo "$command" | grep -oE 'CAMPAIGN_SEEDS=[^ ]+' | cut -d= -f2)): FAILED (exit $exitval)"
            n_failed=$((n_failed + 1))
        fi
    done < "$JOBLOG"
fi

effi_log "  Succeeded: $n_succeeded / $((n_succeeded + n_failed))"

if [ "$n_succeeded" -eq 0 ]; then
    effi_log "FATAL: all workers failed — skipping analysis"
    effi_log "  Check worker logs: $WORKER_LOGS/"
    effi_log "  Check breadcrumbs: $RESULTS_DIR/FAILED-w*.md"
    exit 1
fi

# =========================================================================
# Phase 3: Run analysis on combined results
# =========================================================================

effi_log "=== Phase 3: Analysis ==="

unset CAMPAIGN_SKIP_ANALYZE
CAMPAIGN_ANALYZE_ONLY=1 "$SCRIPT_DIR/campaign.sh"

# =========================================================================
# Summary
# =========================================================================

effi_log "=== Parallel campaign complete ==="
effi_log "  Workers: $n_succeeded succeeded, $n_failed failed"
effi_log "  Job log: $JOBLOG"

if [ "$n_failed" -gt 0 ]; then
    effi_log "  WARNING: $n_failed worker(s) failed — check logs and breadcrumbs"
    exit 1
fi
