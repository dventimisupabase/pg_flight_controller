#!/usr/bin/env bash
# Efficacy campaign orchestrator (Phase 6, increment 6).
#
# Runs the full (arm × fixture × scenario × seed) matrix, drives per-cell
# analysis, and aggregates across seeds.  Resumable: completed trials
# (detected by run_meta.json presence) are skipped on re-run.
#
#   DATABASE_URL="postgres://..." ./efficacy/campaign.sh
#
# Config via env vars:
#
#   CAMPAIGN_PROFILE     profiles/smoke.env   (path to profile env file)
#   CAMPAIGN_ARMS        "defaults expert-static pgfc-active"
#   CAMPAIGN_FIXTURES    "oltp"
#   CAMPAIGN_SCENARIOS   "steady drift"
#   CAMPAIGN_SEEDS       "1 2 3"
#   CAMPAIGN_SKIP_ORACLE  (set to skip oracle sweeps)
#   CAMPAIGN_SKIP_ANALYZE (set to skip analysis phase)
#   CAMPAIGN_ANALYZE_ONLY (set to skip Phase 1 and run only Phase 2/3)
#   CAMPAIGN_DRY_RUN      (set to print matrix without executing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config ---

PROFILE="${CAMPAIGN_PROFILE:-$EFFICACY_DIR/profiles/smoke.env}"

read -ra ARMS      <<< "${CAMPAIGN_ARMS:-defaults expert-static pgfc-active}"
read -ra FIXTURES  <<< "${CAMPAIGN_FIXTURES:-oltp}"
read -ra SCENARIOS <<< "${CAMPAIGN_SCENARIOS:-steady drift}"
read -ra SEEDS     <<< "${CAMPAIGN_SEEDS:-1 2 3}"

DRY_RUN="${CAMPAIGN_DRY_RUN:-}"
SKIP_ORACLE="${CAMPAIGN_SKIP_ORACLE:-}"
SKIP_ANALYZE="${CAMPAIGN_SKIP_ANALYZE:-}"
ANALYZE_ONLY="${CAMPAIGN_ANALYZE_ONLY:-}"

if [ -n "$ANALYZE_ONLY" ] && [ -n "$SKIP_ANALYZE" ]; then
    effi_log "WARNING: CAMPAIGN_ANALYZE_ONLY and CAMPAIGN_SKIP_ANALYZE are mutually exclusive; ignoring SKIP_ANALYZE"
    SKIP_ANALYZE=""
fi

# --- Source profile ---

if [ ! -f "$PROFILE" ]; then
    effi_log "ERROR: profile not found: $PROFILE"
    exit 1
fi
# shellcheck source=profiles/smoke.env
source "$PROFILE"
effi_log "Profile: $(basename "$PROFILE")"

# --- Counts ---

n_arms=${#ARMS[@]}
n_fixtures=${#FIXTURES[@]}
n_scenarios=${#SCENARIOS[@]}
n_seeds=${#SEEDS[@]}
n_trials=$((n_arms * n_fixtures * n_scenarios * n_seeds))
n_oracle=0
if [ -z "$SKIP_ORACLE" ]; then
    n_oracle=$((n_fixtures * n_scenarios * n_seeds))
fi
n_total=$((n_trials + n_oracle))

effi_log "=== Campaign: ${n_arms} arms × ${n_fixtures} fixtures × ${n_scenarios} scenarios × ${n_seeds} seeds = ${n_trials} trials + ${n_oracle} oracle sweeps ==="
effi_log "  Arms:      ${ARMS[*]}"
effi_log "  Fixtures:  ${FIXTURES[*]}"
effi_log "  Scenarios: ${SCENARIOS[*]}"
effi_log "  Seeds:     ${SEEDS[*]}"
effi_log "  Duration:  ${EFFICACY_DURATION:-300}s  Sample: ${EFFICACY_SAMPLE_INTERVAL:-30}s  Rate: ${EFFICACY_PGBENCH_RATE:-10} tps"

# =========================================================================
# Phase 1: Run trials
# =========================================================================

if [ -n "$ANALYZE_ONLY" ]; then
    effi_log "=== Skipping Phase 1 (CAMPAIGN_ANALYZE_ONLY set) ==="
else

effi_log "=== Phase 1: Run trials ==="

trial=0

for fixture in "${FIXTURES[@]}"; do
    for scenario in "${SCENARIOS[@]}"; do
        for seed in "${SEEDS[@]}"; do
            # --- Arm trials ---
            for arm in "${ARMS[@]}"; do
                trial=$((trial + 1))

                if run_dir=$(effi_find_run "$arm" "$fixture" "$scenario" "$seed" 2>/dev/null); then
                    effi_log "[${trial}/${n_total}] SKIP $arm / $fixture / $scenario / s$seed (completed: $(basename "$run_dir"))"
                    continue
                fi

                effi_log "[${trial}/${n_total}] RUN $arm / $fixture / $scenario / s$seed"

                if [ -n "$DRY_RUN" ]; then
                    continue
                fi

                EFFICACY_ARM="$arm" \
                EFFICACY_FIXTURE="$fixture" \
                EFFICACY_SCENARIO="$scenario" \
                EFFICACY_SEED="$seed" \
                    "$SCRIPT_DIR/run.sh"
            done

            # --- Oracle sweep ---
            if [ -z "$SKIP_ORACLE" ]; then
                trial=$((trial + 1))

                if oracle_dir=$(effi_find_oracle "$fixture" "$scenario" "$seed" 2>/dev/null); then
                    effi_log "[${trial}/${n_total}] SKIP oracle / $fixture / $scenario / s$seed (completed: $(basename "$oracle_dir"))"
                    continue
                fi

                effi_log "[${trial}/${n_total}] ORACLE $fixture / $scenario / s$seed"

                if [ -n "$DRY_RUN" ]; then
                    continue
                fi

                EFFICACY_FIXTURE="$fixture" \
                EFFICACY_SCENARIO="$scenario" \
                EFFICACY_SEED="$seed" \
                    "$SCRIPT_DIR/oracle.sh"
            fi
        done
    done
done

if [ -n "$DRY_RUN" ]; then
    effi_log "=== Dry run complete (no trials executed) ==="
    exit 0
fi

fi  # end ANALYZE_ONLY guard

# =========================================================================
# Phase 2: Analyze (per seed)
# =========================================================================

if [ -n "$SKIP_ANALYZE" ]; then
    effi_log "=== Skipping analysis (CAMPAIGN_SKIP_ANALYZE set) ==="
    exit 0
fi

effi_log "=== Phase 2: Analyze (per seed) ==="

for fixture in "${FIXTURES[@]}"; do
    fixture_slug="$(effi_fixture_slug "$fixture")"
    for scenario in "${SCENARIOS[@]}"; do
        for seed in "${SEEDS[@]}"; do
            effi_log "Analyzing: $fixture / $scenario / s$seed"

            defaults_dir=$(effi_find_run "defaults" "$fixture" "$scenario" "$seed" 2>/dev/null) || true
            expert_dir=$(effi_find_run "expert-static" "$fixture" "$scenario" "$seed" 2>/dev/null) || true
            pgfc_dir=$(effi_find_run "pgfc-active" "$fixture" "$scenario" "$seed" 2>/dev/null) || true
            oracle_dir=$(effi_find_oracle "$fixture" "$scenario" "$seed" 2>/dev/null) || true

            missing=()
            [ -z "$defaults_dir" ] && missing+=("defaults")
            [ -z "$expert_dir" ]   && missing+=("expert-static")
            [ -z "$pgfc_dir" ]     && missing+=("pgfc-active")
            [ -z "$oracle_dir" ]   && missing+=("oracle")

            if [ ${#missing[@]} -gt 0 ]; then
                effi_log "  INCOMPLETE: missing ${missing[*]} — skipping analysis"
                continue
            fi

            output_dir="$EFFICACY_DIR/results/analysis-${fixture_slug}-${scenario}-s${seed}"
            mkdir -p "$output_dir"

            "$SCRIPT_DIR/analysis/analyze.sh" \
                --defaults "$defaults_dir" \
                --expert-static "$expert_dir" \
                --pgfc-active "$pgfc_dir" \
                --oracle "$oracle_dir" \
                --output "$output_dir"

            effi_log "  Verdict: $(python3 -c "import json; v=json.load(open('$output_dir/verdict.json')); print(f\"{v['verdict']} (gap-closed: {v['median_gap_closed']})\")")"
        done
    done
done

# =========================================================================
# Phase 3: Aggregate across seeds
# =========================================================================

effi_log "=== Phase 3: Aggregate across seeds ==="

for fixture in "${FIXTURES[@]}"; do
    fixture_slug="$(effi_fixture_slug "$fixture")"
    for scenario in "${SCENARIOS[@]}"; do
        effi_log "Aggregating: $fixture / $scenario (seeds: ${SEEDS[*]})"

        verdict_files=()
        for seed in "${SEEDS[@]}"; do
            vf="$EFFICACY_DIR/results/analysis-${fixture_slug}-${scenario}-s${seed}/verdict.json"
            if [ -f "$vf" ]; then
                verdict_files+=("$vf")
            else
                effi_log "  WARNING: missing verdict for seed $seed"
            fi
        done

        if [ ${#verdict_files[@]} -lt 2 ]; then
            effi_log "  SKIP: need at least 2 seed verdicts for aggregation (have ${#verdict_files[@]})"
            continue
        fi

        agg_dir="$EFFICACY_DIR/results/aggregate-${fixture_slug}-${scenario}"
        mkdir -p "$agg_dir"

        "$SCRIPT_DIR/analysis/aggregate.sh" \
            --output "$agg_dir" \
            "${verdict_files[@]}"

        effi_log "  Cell verdict: $(python3 -c "import json; v=json.load(open('$agg_dir/aggregate.json')); print(f\"{v['cell_verdict']} (median gap-closed: {v['median_gap_closed']}, IQR: [{v['iqr_low']}, {v['iqr_high']}])\")")"
    done
done

effi_log "=== Campaign complete ==="
