#!/usr/bin/env bash
# Cross-seed aggregation (Phase 6, increment 6).
#
# Takes N per-seed verdict.json files and produces a cell-level verdict:
# median gap-closed ± IQR across seeds, worst-case gates.
#
# Usage:
#   ./efficacy/analysis/aggregate.sh --output <dir> <verdict1.json> [verdict2.json ...]
#
# Output:
#   <dir>/aggregate.json       — machine-readable cell verdict
#   <dir>/aggregate_report.md  — human-readable report

set -euo pipefail

# --- Parse arguments ---

OUTPUT_DIR=""
VERDICT_FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *)        VERDICT_FILES+=("$1"); shift ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    echo "ERROR: --output is required" >&2
    exit 1
fi

if [ ${#VERDICT_FILES[@]} -lt 1 ]; then
    echo "ERROR: at least one verdict.json file is required" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# --- Aggregate via Python ---

python3 - "$OUTPUT_DIR" "${VERDICT_FILES[@]}" <<'PYEOF'
import json, sys, os

out_dir = sys.argv[1]
verdict_paths = sys.argv[2:]

verdicts = []
for path in verdict_paths:
    with open(path) as f:
        verdicts.append(json.load(f))

n_seeds = len(verdicts)

def median(vals):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2

def percentile(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    n = len(s)
    k = (n - 1) * p
    f = int(k)
    c = f + 1
    if c >= n:
        return s[f]
    return s[f] + (k - f) * (s[c] - s[f])

gc_values = [v['median_gap_closed'] for v in verdicts
             if v.get('median_gap_closed') is not None]

median_gc = median(gc_values) if gc_values else None
iqr_low = percentile(gc_values, 0.25) if gc_values else None
iqr_high = percentile(gc_values, 0.75) if gc_values else None

any_cost_ceiling = any(v.get('cost_ceiling_breach', False) for v in verdicts)
any_av_ceiling = any(v.get('av_ceiling_breach', False) for v in verdicts)
any_mutation_ceiling = any(v.get('mutation_ceiling_breach', False) for v in verdicts)
any_safety_violation = any(
    v.get('safety_floor_evaluated', False) and not v.get('safety_floor_holds', True)
    for v in verdicts
)
any_gate_failure = any_cost_ceiling or any_safety_violation

# Cell verdict
if median_gc is None:
    cell_verdict = "inconclusive"
elif any_safety_violation:
    cell_verdict = "fail"
elif any_cost_ceiling and median_gc > 0:
    cell_verdict = "fail"
elif median_gc < 0:
    cell_verdict = "fail"
elif median_gc >= 0.25:
    cell_verdict = "strong_pass"
else:
    cell_verdict = "pass"

# Round for display
def fmt(v):
    if v is None:
        return None
    r = round(v, 6)
    return 0.0 if r == 0.0 else r

per_seed = []
for i, v in enumerate(verdicts):
    seed_num = i + 1
    parts = os.path.basename(os.path.dirname(verdict_paths[i])).split('-')
    for part in parts:
        if part.startswith('s') and part[1:].isdigit():
            seed_num = int(part[1:])
            break
    per_seed.append({
        "seed": seed_num,
        "verdict": v.get("verdict", "inconclusive"),
        "median_gap_closed": fmt(v.get("median_gap_closed")),
        "windows_scored": v.get("windows_scored", 0),
        "cost_ceiling_breach": v.get("cost_ceiling_breach", False),
        "safety_floor_holds": v.get("safety_floor_holds", True),
    })

agg = {
    "cell_verdict": cell_verdict,
    "median_gap_closed": fmt(median_gc),
    "iqr_low": fmt(iqr_low),
    "iqr_high": fmt(iqr_high),
    "n_seeds": n_seeds,
    "per_seed": per_seed,
    "any_cost_ceiling_breach": any_cost_ceiling,
    "any_av_ceiling_breach": any_av_ceiling,
    "any_mutation_ceiling_breach": any_mutation_ceiling,
    "any_safety_floor_violation": any_safety_violation,
    "any_gate_failure": any_gate_failure,
}

with open(os.path.join(out_dir, 'aggregate.json'), 'w') as f:
    json.dump(agg, f, indent=2)

# --- Report ---

lines = []
lines.append("# Cross-seed aggregation report")
lines.append("")
lines.append(f"**Cell verdict: {cell_verdict.upper().replace('_', ' ')}**")
lines.append("")
lines.append("## Summary")
lines.append("")
gc_str = f"{fmt(median_gc):.4f}" if median_gc is not None else "N/A"
iqr_lo = f"{fmt(iqr_low):.4f}" if iqr_low is not None else "N/A"
iqr_hi = f"{fmt(iqr_high):.4f}" if iqr_high is not None else "N/A"
lines.append(f"- Median gap-closed across seeds: **{gc_str}**")
lines.append(f"- IQR: [{iqr_lo}, {iqr_hi}]")
lines.append(f"- Seeds: {n_seeds}")
lines.append("")
lines.append("## Per-seed results")
lines.append("")
lines.append("| Seed | Verdict | gap-closed | Windows scored | Cost ceiling | Safety floor |")
lines.append("|---|---|---|---|---|---|")
for s in per_seed:
    gc_s = f"{s['median_gap_closed']:.4f}" if s['median_gap_closed'] is not None else "N/A"
    lines.append(f"| {s['seed']} | {s['verdict']} | {gc_s} | {s['windows_scored']} | "
                 f"{'BREACH' if s['cost_ceiling_breach'] else 'OK'} | "
                 f"{'OK' if s['safety_floor_holds'] else 'VIOLATION'} |")
lines.append("")
lines.append("## Gates (worst-case across seeds)")
lines.append("")
lines.append(f"- Cost ceiling: **{'BREACH' if any_cost_ceiling else 'OK'}**")
lines.append(f"- Safety floor: **{'VIOLATION' if any_safety_violation else 'OK'}**")
lines.append("")
if n_seeds <= 3:
    lines.append(f"> **Note:** IQR with n={n_seeds} is coarse (Q1 ≈ min, Q3 ≈ max).")
    lines.append("")

with open(os.path.join(out_dir, 'aggregate_report.md'), 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"Cell verdict: {cell_verdict} (median gap-closed: {gc_str})", file=sys.stderr)
PYEOF
