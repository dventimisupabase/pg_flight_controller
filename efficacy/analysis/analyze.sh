#!/usr/bin/env bash
# Efficacy analysis pipeline (Phase 6, increment 5).
#
# Takes the result directories from four arms (defaults, expert-static,
# pgfc-active) plus the oracle directory, computes gap_closed per window,
# applies cost-ceiling and safety-floor gates, and emits a verdict.
#
# Usage:
#   ./efficacy/analysis/analyze.sh \
#       --defaults <run-dir> \
#       --expert-static <run-dir> \
#       --pgfc-active <run-dir> \
#       --oracle <oracle-dir> \
#       --output <output-dir>
#
# Output:
#   <output-dir>/verdict.json   — machine-readable verdict
#   <output-dir>/report.md      — human-readable report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P95_SCRIPT="$SCRIPT_DIR/p95-from-log.sh"

# --- Parse arguments ---

DEFAULTS_DIR="" EXPERT_DIR="" PGFC_DIR="" ORACLE_DIR="" OUTPUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --defaults)       DEFAULTS_DIR="$2"; shift 2 ;;
        --expert-static)  EXPERT_DIR="$2";   shift 2 ;;
        --pgfc-active)    PGFC_DIR="$2";     shift 2 ;;
        --oracle)         ORACLE_DIR="$2";   shift 2 ;;
        --output)         OUTPUT_DIR="$2";   shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

for var in DEFAULTS_DIR EXPERT_DIR PGFC_DIR ORACLE_DIR OUTPUT_DIR; do
    if [ -z "${!var}" ]; then
        echo "ERROR: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]' | sed 's/-dir//') is required" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# --- Validate sample_interval_s matches across runs ---

read_interval() {
    python3 -c "import json; print(json.load(open('$1/run_meta.json'))['sample_interval_s'])"
}

WINDOW_S=$(read_interval "$DEFAULTS_DIR")
for d in "$EXPERT_DIR" "$PGFC_DIR" "$ORACLE_DIR"; do
    interval=$(read_interval "$d")
    if [ "$interval" != "$WINDOW_S" ]; then
        echo "ERROR: sample_interval_s mismatch: defaults=$WINDOW_S, $(basename "$d")=$interval" >&2
        exit 1
    fi
done
log "Window size: ${WINDOW_S}s"

# --- Compute per-window p95 for each arm ---

compute_p95() {
    local dir="$1" out="$2"
    local log_files=()
    while IFS= read -r f; do
        log_files+=("$f")
    done < <(find "$dir" -name 'pgbench_log*' -not -name '*.txt' -type f 2>/dev/null)

    if [ ${#log_files[@]} -eq 0 ]; then
        echo "ERROR: no pgbench log files in $dir" >&2
        exit 1
    fi

    "$P95_SCRIPT" "$WINDOW_S" "${log_files[@]}" > "$out"
}

compute_p95 "$DEFAULTS_DIR" "$OUTPUT_DIR/_defaults_p95.tsv"
compute_p95 "$EXPERT_DIR"   "$OUTPUT_DIR/_expert_p95.tsv"
compute_p95 "$PGFC_DIR"     "$OUTPUT_DIR/_pgfc_p95.tsv"

# Oracle p95 is pre-computed in oracle_best.csv (tab-separated, header: window best_sf best_p95_us)
tail -n +2 "$ORACLE_DIR/oracle_best.csv" | awk -F'\t' '{ printf "%d\t%d\n", $1, $3 }' \
    > "$OUTPUT_DIR/_oracle_p95.tsv"

log "Per-window p95 computed for all arms"

# Write a manifest so the Python analysis can find the original directories.
cat > "$OUTPUT_DIR/_manifest.json" <<EOJSON
{
  "defaults_dir": "$DEFAULTS_DIR",
  "expert_dir": "$EXPERT_DIR",
  "pgfc_dir": "$PGFC_DIR",
  "oracle_dir": "$ORACLE_DIR"
}
EOJSON

# --- Inner join on window number, compute gap_closed ---
#
# Join expert ∩ pgfc ∩ oracle on window number.
# Discard first 20% of windows (warm-up).
# Guard: skip windows where (expert - oracle) <= 0.

python3 - "$OUTPUT_DIR" "$WINDOW_S" <<'PYEOF'
import csv, json, sys, os
from pathlib import Path

out_dir = sys.argv[1]
window_s = int(sys.argv[2])

def load_p95(path):
    """Load TSV: window p95_us [tx_count]. Returns {window: p95_us}."""
    result = {}
    with open(path) as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 2:
                result[int(parts[0])] = int(parts[1])
    return result

defaults_p95 = load_p95(os.path.join(out_dir, '_defaults_p95.tsv'))
expert_p95   = load_p95(os.path.join(out_dir, '_expert_p95.tsv'))
pgfc_p95     = load_p95(os.path.join(out_dir, '_pgfc_p95.tsv'))
oracle_p95   = load_p95(os.path.join(out_dir, '_oracle_p95.tsv'))

# Inner join on window number
common_windows = sorted(set(expert_p95) & set(pgfc_p95) & set(oracle_p95))
total_windows = len(common_windows)

if total_windows == 0:
    print("ERROR: no common windows across expert, pgfc, and oracle", file=sys.stderr)
    sys.exit(1)

# Warm-up discard: first 20%
n_warmup = max(1, int(total_windows * 0.20))
graded_windows = common_windows[n_warmup:]

if len(graded_windows) == 0:
    print("ERROR: no windows remain after warm-up discard", file=sys.stderr)
    sys.exit(1)

# Compute gap_closed per window, guarding the denominator
gap_closed_values = []
windows_dropped_denom = 0
per_window = []

for w in graded_windows:
    e = expert_p95[w]
    p = pgfc_p95[w]
    o = oracle_p95[w]
    denom = e - o

    entry = {"window": w, "expert_p95": e, "pgfc_p95": p, "oracle_p95": o}

    if denom <= 0:
        windows_dropped_denom += 1
        entry["gap_closed"] = None
        entry["dropped"] = True
        entry["drop_reason"] = "denom_le_zero"
    else:
        gc = (e - p) / denom
        gap_closed_values.append(gc)
        entry["gap_closed"] = round(gc, 6)
        entry["dropped"] = False

    per_window.append(entry)

# Median of gap_closed values
def median(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    else:
        return (s[n // 2 - 1] + s[n // 2]) / 2

median_gc = median(gap_closed_values)

# --- Cost ceiling ---

def load_metrics(run_dir):
    """Load efficacy_metrics.csv, return list of dicts."""
    path = os.path.join(run_dir, 'efficacy_metrics.csv')
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))

manifest_path = os.path.join(out_dir, '_manifest.json')
if os.path.exists(manifest_path):
    manifest = json.load(open(manifest_path))
    defaults_metrics = load_metrics(manifest['defaults_dir'])
    pgfc_metrics = load_metrics(manifest['pgfc_dir'])
else:
    defaults_metrics = []
    pgfc_metrics = []

# Max av_count across all samples (cumulative counter, so max = final)
def max_field(metrics, field):
    vals = [int(r[field]) for r in metrics if r.get(field) and r[field] != '']
    return max(vals) if vals else 0

defaults_av = max_field(defaults_metrics, 'av_count')
pgfc_av = max_field(pgfc_metrics, 'av_count')
pgfc_applied = max_field(pgfc_metrics, 'pgfc_applied')

DAILY_MUTATION_BUDGET = 500

av_ceiling_breach = (defaults_av > 0 and pgfc_av > 2 * defaults_av)
mutation_ceiling_breach = (pgfc_applied > DAILY_MUTATION_BUDGET)
cost_ceiling_breach = av_ceiling_breach or mutation_ceiling_breach

# --- Safety floor ---

def max_xid_age(metrics):
    vals = [int(r['xid_age']) for r in metrics if r.get('xid_age') and r['xid_age'] != '']
    return max(vals) if vals else 0

def read_freeze_max_age(run_dir):
    """Read autovacuum_freeze_max_age from run_meta.json, or None if absent."""
    meta_path = os.path.join(run_dir, 'run_meta.json')
    if not os.path.exists(meta_path):
        return None
    meta = json.load(open(meta_path))
    return meta.get('autovacuum_freeze_max_age')

freeze_max_age = None
if os.path.exists(manifest_path):
    for key in ['defaults_dir', 'pgfc_dir']:
        v = read_freeze_max_age(manifest[key])
        if v is not None:
            freeze_max_age = int(v)
            break

all_metrics = defaults_metrics + pgfc_metrics
worst_xid = max_xid_age(all_metrics)

if freeze_max_age is not None:
    safety_floor_holds = (worst_xid < freeze_max_age)
    safety_floor_evaluated = True
else:
    safety_floor_holds = None
    safety_floor_evaluated = False

# --- Verdict ---

if median_gc is None:
    verdict = "inconclusive"
elif safety_floor_evaluated and not safety_floor_holds:
    verdict = "fail"
elif cost_ceiling_breach and median_gc > 0:
    verdict = "fail"
elif median_gc < 0:
    verdict = "fail"
elif median_gc >= 0.25:
    verdict = "strong_pass"
else:
    verdict = "pass"

# Round for display
display_gc = round(median_gc, 6) if median_gc is not None else None
# Normalize -0.0 to 0.0
if display_gc is not None and display_gc == 0.0:
    display_gc = 0.0

# --- Emit verdict.json ---

verdict_data = {
    "verdict": verdict,
    "median_gap_closed": display_gc,
    "total_windows": total_windows,
    "warmup_discarded": n_warmup,
    "graded_windows": len(graded_windows),
    "windows_dropped_denom": windows_dropped_denom,
    "windows_scored": len(gap_closed_values),
    "cost_ceiling_breach": cost_ceiling_breach,
    "av_ceiling_breach": av_ceiling_breach,
    "mutation_ceiling_breach": mutation_ceiling_breach,
    "defaults_av_count": defaults_av,
    "pgfc_av_count": pgfc_av,
    "pgfc_applied": pgfc_applied,
    "safety_floor_evaluated": safety_floor_evaluated,
    "safety_floor_holds": safety_floor_holds,
    "freeze_max_age": freeze_max_age,
    "worst_xid_age": worst_xid,
    "per_window": per_window
}

with open(os.path.join(out_dir, 'verdict.json'), 'w') as f:
    json.dump(verdict_data, f, indent=2)

# --- Emit report.md ---

lines = []
lines.append("# Efficacy analysis report")
lines.append("")
lines.append(f"**Verdict: {verdict.upper().replace('_', ' ')}**")
lines.append("")
lines.append("## Summary")
lines.append("")
gc_str = f"{display_gc:.4f}" if display_gc is not None else "N/A"
lines.append(f"- Median gap-closed: **{gc_str}**")
lines.append(f"- Windows: {total_windows} total, {n_warmup} warm-up discarded, "
             f"{len(graded_windows)} graded, {windows_dropped_denom} dropped (denominator ≤ 0), "
             f"{len(gap_closed_values)} scored")
lines.append("")
lines.append("## Gates")
lines.append("")

# Verdict thresholds
lines.append("### Verdict thresholds")
lines.append("")
lines.append("| Threshold | Required | Actual | Status |")
lines.append("|---|---|---|---|")
lines.append(f"| gap-closed ≥ 0.0 (pass) | ≥ 0.0 | {gc_str} | {'PASS' if display_gc is not None and display_gc >= 0 else 'FAIL'} |")
lines.append(f"| gap-closed ≥ 0.25 (strong) | ≥ 0.25 | {gc_str} | {'PASS' if display_gc is not None and display_gc >= 0.25 else '—'} |")
lines.append("")

# Cost ceiling
lines.append("### Cost ceiling")
lines.append("")
lines.append(f"- Autovacuum frequency: pgfc={pgfc_av}, defaults={defaults_av}, "
             f"ratio={'∞' if defaults_av == 0 else f'{pgfc_av/defaults_av:.1f}'}x "
             f"(ceiling: ≤ 2.0x) → **{'BREACH' if av_ceiling_breach else 'OK'}**")
lines.append(f"- pgfc mutations: {pgfc_applied} (budget: {DAILY_MUTATION_BUDGET}) → "
             f"**{'BREACH' if mutation_ceiling_breach else 'OK'}**")
lines.append("")
lines.append("> **Limitation:** Phase 2 specifies the cost ceiling as ≤ 2× the defaults arm's")
lines.append("> autovacuum *I/O* (pages read/written). The harness collects autovacuum *count*")
lines.append("> (`av_count`) but not per-run I/O. This analysis uses frequency as a proxy.")
lines.append("> A proper I/O ceiling requires `log_autovacuum_min_duration = 0` and log parsing.")
lines.append("")

# Safety floor
lines.append("### Safety floor")
lines.append("")
if safety_floor_evaluated:
    lines.append(f"- Worst xid age: {worst_xid} (limit: {freeze_max_age:,}) → "
                 f"**{'OK' if safety_floor_holds else 'VIOLATION'}**")
else:
    lines.append(f"- Worst xid age: {worst_xid} — **NOT EVALUATED** "
                 f"(autovacuum_freeze_max_age not recorded in run_meta.json)")
lines.append("")

# Per-window detail
lines.append("## Per-window detail")
lines.append("")
lines.append("| Window | Expert p95 (µs) | pgfc p95 (µs) | Oracle p95 (µs) | gap-closed | Note |")
lines.append("|---|---|---|---|---|---|")
for entry in per_window:
    gc_cell = f"{entry['gap_closed']:.4f}" if entry['gap_closed'] is not None else "—"
    note = entry.get('drop_reason', '')
    lines.append(f"| {entry['window']} | {entry['expert_p95']:,} | {entry['pgfc_p95']:,} | "
                 f"{entry['oracle_p95']:,} | {gc_cell} | {note} |")
lines.append("")

with open(os.path.join(out_dir, 'report.md'), 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"Verdict: {verdict} (median gap-closed: {gc_str})", file=sys.stderr)
PYEOF

# Clean up intermediate files
rm -f "$OUTPUT_DIR/_defaults_p95.tsv" "$OUTPUT_DIR/_expert_p95.tsv" \
      "$OUTPUT_DIR/_pgfc_p95.tsv" "$OUTPUT_DIR/_oracle_p95.tsv" \
      "$OUTPUT_DIR/_manifest.json"

log "Analysis complete → $OUTPUT_DIR"
