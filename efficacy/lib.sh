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

effi_fixture_slug() {
    echo "${1//_/-}"
}

effi_run_id() {
    local arm="${1:?arm}" fixture="${2:?fixture}" scenario="${3:?scenario}" seed="${4:?seed}"
    local slug
    slug="$(effi_fixture_slug "$fixture")"
    printf '%s-%s-%s-s%s-%s' "$arm" "$slug" "$scenario" "$seed" "$(date -u +%Y%m%dT%H%M%SZ)"
}

effi_find_run() {
    local arm="${1:?arm}" fixture="${2:?fixture}" scenario="${3:?scenario}" seed="${4:?seed}"
    python3 -c "
import json, os, sys

target = {'arm': sys.argv[1], 'fixture': sys.argv[2],
          'scenario': sys.argv[3], 'seed': int(sys.argv[4])}
results = os.path.join(sys.argv[5], 'results')
best = None

for d in sorted(os.listdir(results), reverse=True) if os.path.isdir(results) else []:
    meta_path = os.path.join(results, d, 'run_meta.json')
    if not os.path.isfile(meta_path):
        continue
    try:
        m = json.load(open(meta_path))
    except (json.JSONDecodeError, OSError):
        continue
    if (m.get('arm') == target['arm']
        and m.get('fixture') == target['fixture']
        and m.get('scenario') == target['scenario']
        and int(m.get('seed', -1)) == target['seed']):
        print(os.path.join(results, d))
        sys.exit(0)

sys.exit(1)
" "$arm" "$fixture" "$scenario" "$seed" "$EFFICACY_DIR"
}

effi_find_oracle() {
    local fixture="${1:?fixture}" scenario="${2:?scenario}" seed="${3:?seed}"
    python3 -c "
import json, os, sys

target = {'fixture': sys.argv[1], 'scenario': sys.argv[2], 'seed': int(sys.argv[3])}
results = os.path.join(sys.argv[4], 'results')

for d in sorted(os.listdir(results), reverse=True) if os.path.isdir(results) else []:
    meta_path = os.path.join(results, d, 'run_meta.json')
    best_path = os.path.join(results, d, 'oracle_best.csv')
    if not os.path.isfile(meta_path) or not os.path.isfile(best_path):
        continue
    try:
        m = json.load(open(meta_path))
    except (json.JSONDecodeError, OSError):
        continue
    if (m.get('fixture') == target['fixture']
        and m.get('scenario') == target['scenario']
        and int(m.get('seed', -1)) == target['seed']):
        print(os.path.join(results, d))
        sys.exit(0)

sys.exit(1)
" "$fixture" "$scenario" "$seed" "$EFFICACY_DIR"
}

effi_find_oracle_probe() {
    local fixture="${1:?fixture}" scenario="${2:?scenario}" seed="${3:?seed}" sf="${4:?sf}"
    python3 -c "
import json, os, sys

target = {'arm': 'oracle-probe', 'fixture': sys.argv[1],
          'scenario': sys.argv[2], 'seed': int(sys.argv[3]),
          'oracle_sf': float(sys.argv[4])}
results = os.path.join(sys.argv[5], 'results')

for d in sorted(os.listdir(results), reverse=True) if os.path.isdir(results) else []:
    meta_path = os.path.join(results, d, 'run_meta.json')
    if not os.path.isfile(meta_path):
        continue
    try:
        m = json.load(open(meta_path))
    except (json.JSONDecodeError, OSError):
        continue
    sf_val = m.get('oracle_sf')
    if sf_val is None:
        continue
    if (m.get('arm') == target['arm']
        and m.get('fixture') == target['fixture']
        and m.get('scenario') == target['scenario']
        and int(m.get('seed', -1)) == target['seed']
        and abs(float(sf_val) - target['oracle_sf']) < 1e-9):
        print(os.path.join(results, d))
        sys.exit(0)

sys.exit(1)
" "$fixture" "$scenario" "$seed" "$sf" "$EFFICACY_DIR"
}
