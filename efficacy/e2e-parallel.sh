#!/usr/bin/env bash
# Parallel e2e campaign lifecycle — one project per trial.
#
# Enumerates all (arm × fixture × scenario × seed) trials and oracle probes
# as independent work units, each provisioned on its own Supabase project.
# After all work units finish, runs oracle aggregation and campaign analysis
# locally.
#
#   E2E_ORG_ID=<org> E2E_WORKERS=24 ./efficacy/e2e-parallel.sh
#
# Config via env vars:
#
#   E2E_WORKERS          1           number of parallel workers (1 = delegate to e2e.sh)
#   E2E_ORG_ID           (required)  Supabase org
#   E2E_REGION           us-east-1
#   E2E_SIZE             small
#   E2E_SUPABASE_DOMAIN  supabase.green
#   E2E_MAX_RETRIES      3
#   E2E_RETRY_DELAY      10
#   E2E_READINESS_TIMEOUT 300
#
#   Campaign matrix:
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
TS="$(date -u +%Y%m%dT%H%M%SZ)"

read -ra ARMS      <<< "${CAMPAIGN_ARMS:-defaults expert-static pgfc-active}"
read -ra FIXTURES  <<< "${CAMPAIGN_FIXTURES:-oltp}"
read -ra SCENARIOS <<< "${CAMPAIGN_SCENARIOS:-steady drift}"
read -ra SEEDS     <<< "${CAMPAIGN_SEEDS:-1 2 3}"
SKIP_ORACLE="${CAMPAIGN_SKIP_ORACLE:-}"

PROFILE="${CAMPAIGN_PROFILE:-$EFFICACY_DIR/profiles/smoke.env}"
if [ ! -f "$PROFILE" ]; then
    effi_log "ERROR: profile not found: $PROFILE"
    exit 1
fi
# shellcheck source=profiles/smoke.env
source "$PROFILE"

SF_GRID=(0.005 0.01 0.02 0.05 0.10 0.20 0.30 0.50)

# --- Single-worker fast path ---

if [ "$N_WORKERS" -le 1 ]; then
    exec "$SCRIPT_DIR/e2e.sh"
fi

# --- Preflight ---

: "${E2E_ORG_ID:?E2E_ORG_ID is required (run: supabase orgs list)}"

effi_require parallel
effi_require supabase
effi_require psql
effi_require pgbench
effi_require jq
effi_require openssl

# --- Enumerate work units ---
# Format: type|arm|fixture|scenario|seed|sf
# For trials, sf is empty.  For oracle probes, sf is the grid value.

WORK_UNITS=()

for fixture in "${FIXTURES[@]}"; do
    for scenario in "${SCENARIOS[@]}"; do
        for seed in "${SEEDS[@]}"; do
            for arm in "${ARMS[@]}"; do
                WORK_UNITS+=("trial|$arm|$fixture|$scenario|$seed|")
            done
            if [ -z "$SKIP_ORACLE" ]; then
                for sf in "${SF_GRID[@]}"; do
                    WORK_UNITS+=("probe|oracle-probe|$fixture|$scenario|$seed|$sf")
                done
            fi
        done
    done
done

n_trials=0
n_probes=0
for unit in "${WORK_UNITS[@]}"; do
    case "${unit%%|*}" in
        trial) n_trials=$((n_trials + 1)) ;;
        probe) n_probes=$((n_probes + 1)) ;;
    esac
done

n_total=${#WORK_UNITS[@]}

effi_log "=== Parallel E2E Campaign (per-trial) ==="
effi_log "  Work units:  $n_total ($n_trials trials + $n_probes oracle probes)"
effi_log "  Workers:     $N_WORKERS"
effi_log "  Arms:        ${ARMS[*]}"
effi_log "  Fixtures:    ${FIXTURES[*]}"
effi_log "  Scenarios:   ${SCENARIOS[*]}"
effi_log "  Seeds:       ${SEEDS[*]}"
effi_log "  Duration:    active=${EFFICACY_DURATION:-300}s  static=${EFFICACY_STATIC_DURATION:-900}s"
effi_log "  Org:         $E2E_ORG_ID"
effi_log "  Region:      ${E2E_REGION:-us-east-1}"
effi_log "  Size:        ${E2E_SIZE:-micro}"

if [ "$N_WORKERS" -gt "$n_total" ]; then
    effi_log "WARNING: E2E_WORKERS ($N_WORKERS) > work units ($n_total); capping at $n_total"
    N_WORKERS="$n_total"
fi

# --- Dry-run fast path ---

if [ -n "${CAMPAIGN_DRY_RUN:-}" ]; then
    effi_log "=== Dry run: enumerating work units ==="
    idx=0
    for unit in "${WORK_UNITS[@]}"; do
        idx=$((idx + 1))
        IFS='|' read -r type arm fixture scenario seed sf <<< "$unit"
        if [ "$type" = "trial" ]; then
            effi_log "  [$idx/$n_total] TRIAL $arm / $fixture / $scenario / s$seed"
        else
            effi_log "  [$idx/$n_total] PROBE $fixture / $scenario / s$seed / sf=$sf"
        fi
    done
    effi_log "=== Dry run complete ==="
    exit 0
fi

# --- Skip-completed logic ---

PENDING_UNITS=()
n_skipped=0

for unit in "${WORK_UNITS[@]}"; do
    IFS='|' read -r type arm fixture scenario seed sf <<< "$unit"
    if [ "$type" = "trial" ]; then
        if effi_find_run "$arm" "$fixture" "$scenario" "$seed" >/dev/null 2>&1; then
            effi_log "  SKIP (completed): $arm / $fixture / $scenario / s$seed"
            n_skipped=$((n_skipped + 1))
            continue
        fi
    else
        if effi_find_oracle_probe "$fixture" "$scenario" "$seed" "$sf" >/dev/null 2>&1; then
            effi_log "  SKIP (completed): oracle-probe / $fixture / $scenario / s$seed / sf=$sf"
            n_skipped=$((n_skipped + 1))
            continue
        fi
    fi
    PENDING_UNITS+=("$unit")
done

if [ "$n_skipped" -gt 0 ]; then
    effi_log "  Skipped $n_skipped completed work units, ${#PENDING_UNITS[@]} remaining"
fi

if [ ${#PENDING_UNITS[@]} -eq 0 ]; then
    effi_log "All work units already completed — skipping to analysis."
else

# =========================================================================
# Phase 1: Launch work units via GNU Parallel
# =========================================================================

effi_log "=== Phase 1: Launching ${#PENDING_UNITS[@]} work units across $N_WORKERS workers ==="

RESULTS_DIR="$EFFICACY_DIR/results"
JOBLOG="$RESULTS_DIR/parallel-joblog-${TS}.txt"
WORKER_LOGS="$RESULTS_DIR/parallel-logs-${TS}"
mkdir -p "$RESULTS_DIR" "$WORKER_LOGS"

# GNU Parallel splits each line on '|' and substitutes {1}..{6} into the
# command template.  e2e.sh computes its own project name from the env vars.
printf '%s\n' "${PENDING_UNITS[@]}" | \
    parallel --colsep '\|' \
        -j "$N_WORKERS" \
        --delay 5 \
        --halt never \
        --joblog "$JOBLOG" \
        env \
            E2E_SINGLE_TRIAL=1 \
            E2E_AUTO_TEARDOWN=1 \
            E2E_WORKER_ID='{#}' \
            EFFICACY_ARM='{2}' \
            EFFICACY_FIXTURE='{3}' \
            EFFICACY_SCENARIO='{4}' \
            EFFICACY_SEED='{5}' \
            EFFICACY_ORACLE_SF='{6}' \
            CAMPAIGN_PROFILE="$PROFILE" \
            "$SCRIPT_DIR/e2e.sh" \
        '>' "$WORKER_LOGS/{1}-{2}-{3}-{4}-s{5}-sf{6}.log" '2>&1' \
    || true

# =========================================================================
# Phase 2: Inspect results
# =========================================================================

effi_log "=== Phase 2: Worker results ==="

n_succeeded=0
n_failed=0

if [ -f "$JOBLOG" ]; then
    while IFS=$'\t' read -r seq _host _starttime jobruntime _send _receive exitval _signal _command _rest; do
        [ "$seq" = "Seq" ] && continue
        if [ "$exitval" -eq 0 ]; then
            effi_log "  Job $seq: OK (${jobruntime}s)"
            n_succeeded=$((n_succeeded + 1))
        else
            effi_log "  Job $seq: FAILED (exit $exitval)"
            n_failed=$((n_failed + 1))
        fi
    done < "$JOBLOG"
fi

effi_log "  Succeeded: $n_succeeded / $((n_succeeded + n_failed))"

if [ "$n_succeeded" -eq 0 ] && [ ${#PENDING_UNITS[@]} -gt 0 ]; then
    effi_log "FATAL: all work units failed — skipping analysis"
    effi_log "  Check logs: $WORKER_LOGS/"
    effi_log "  Check breadcrumbs: $RESULTS_DIR/FAILED-w*.md"
    exit 1
fi

fi  # end PENDING_UNITS guard

# =========================================================================
# Phase 3: Oracle aggregation (local, no DB needed)
# =========================================================================

if [ -z "$SKIP_ORACLE" ]; then
    effi_log "=== Phase 3: Oracle aggregation ==="

    for fixture in "${FIXTURES[@]}"; do
        for scenario in "${SCENARIOS[@]}"; do
            for seed in "${SEEDS[@]}"; do
                if effi_find_oracle "$fixture" "$scenario" "$seed" >/dev/null 2>&1; then
                    effi_log "  SKIP (completed): oracle / $fixture / $scenario / s$seed"
                    continue
                fi

                effi_log "  Aggregating: $fixture / $scenario / s$seed"
                if ! ORACLE_AGGREGATE_ONLY=1 \
                    EFFICACY_FIXTURE="$fixture" \
                    EFFICACY_SCENARIO="$scenario" \
                    EFFICACY_SEED="$seed" \
                    EFFICACY_SAMPLE_INTERVAL="${EFFICACY_SAMPLE_INTERVAL:-30}" \
                        "$SCRIPT_DIR/oracle.sh"; then
                    effi_log "  WARNING: skipping incomplete oracle sweep ($fixture / $scenario / s$seed)"
                fi
            done
        done
    done
fi

# =========================================================================
# Phase 4: Campaign analysis (local, no DB needed)
# =========================================================================

effi_log "=== Phase 4: Campaign analysis ==="

CAMPAIGN_ANALYZE_ONLY=1 "$SCRIPT_DIR/campaign.sh"

# =========================================================================
# Summary
# =========================================================================

effi_log "=== Parallel campaign complete ==="
if [ -n "${JOBLOG:-}" ] && [ -f "$JOBLOG" ]; then
    effi_log "  Job log: $JOBLOG"
fi
if [ -n "${n_failed:-}" ] && [ "$n_failed" -gt 0 ]; then
    effi_log "  WARNING: $n_failed work unit(s) failed — check logs and breadcrumbs"
    exit 1
fi
