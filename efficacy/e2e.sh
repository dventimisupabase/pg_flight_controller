#!/usr/bin/env bash
# End-to-end efficacy campaign lifecycle.
#
# Provisions a Supabase project, configures it, runs the full campaign matrix,
# verifies results landed on local disk, and tears down the project.
#
#   ./efficacy/e2e.sh
#
# Config via env vars:
#
#   E2E_ORG_ID           (required) Supabase org to create the project in
#   E2E_REGION           us-east-1
#   E2E_SIZE             micro
#   E2E_PROJECT_NAME     pgfc-efficacy-<timestamp>
#   E2E_MAX_RETRIES      3           retries per transient step
#   E2E_RETRY_DELAY      10          seconds between retries
#   E2E_READINESS_TIMEOUT 300        seconds to wait for project readiness
#   E2E_SUPABASE_DOMAIN  supabase.green  domain suffix (supabase.green for staging,
#                                         supabase.com for production)
#
#   Campaign pass-through (forwarded to campaign.sh):
#   CAMPAIGN_PROFILE     profiles/smoke.env
#   CAMPAIGN_ARMS        "defaults expert-static pgfc-active"
#   CAMPAIGN_FIXTURES    "oltp"
#   CAMPAIGN_SCENARIOS   "steady drift"
#   CAMPAIGN_SEEDS       "1 2 3"
#   CAMPAIGN_SKIP_ORACLE
#   CAMPAIGN_SKIP_ANALYZE
#   CAMPAIGN_DRY_RUN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config ---

ORG_ID="${E2E_ORG_ID:?E2E_ORG_ID is required (run: supabase orgs list)}"
REGION="${E2E_REGION:-us-east-1}"
SIZE="${E2E_SIZE:-micro}"
PROJECT_NAME="${E2E_PROJECT_NAME:-pgfc-efficacy-$(date -u +%Y%m%dT%H%M%SZ)}"
MAX_RETRIES="${E2E_MAX_RETRIES:-3}"
RETRY_DELAY="${E2E_RETRY_DELAY:-10}"
READINESS_TIMEOUT="${E2E_READINESS_TIMEOUT:-300}"
SUPABASE_DOMAIN="${E2E_SUPABASE_DOMAIN:-supabase.green}"

PROFILE="${CAMPAIGN_PROFILE:-$EFFICACY_DIR/profiles/smoke.env}"
if [ ! -f "$PROFILE" ]; then
    effi_log "ERROR: profile not found: $PROFILE"
    exit 1
fi
# shellcheck source=profiles/smoke.env
source "$PROFILE"

STATEMENT_TIMEOUT="${E2E_STATEMENT_TIMEOUT:-$((EFFICACY_DURATION + 300))s}"

DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

PROJECT_REF=""
CAMPAIGN_SUCCEEDED=""
BREADCRUMB_DIR="$EFFICACY_DIR/results"
BREADCRUMB_FILE=""

# --- Helpers ---

retry() {
    local label="$1" max="$2" delay="$3"
    shift 3
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$max" ]; then
            effi_log "FAILED: $label after $max attempts"
            return 1
        fi
        effi_log "  $label: attempt $attempt/$max failed, retrying in ${delay}s..."
        attempt=$((attempt + 1))
        sleep "$delay"
    done
}

drop_breadcrumb() {
    local reason="$1" phase="$2"
    BREADCRUMB_FILE="$BREADCRUMB_DIR/FAILED-$(date -u +%Y%m%dT%H%M%SZ).md"
    mkdir -p "$BREADCRUMB_DIR"
    cat > "$BREADCRUMB_FILE" <<EOF
# E2E Campaign Failure

- **Time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
- **Phase:** $phase
- **Reason:** $reason

## Project

- **Ref:** ${PROJECT_REF:-<not created>}
- **Region:** $REGION
- **Name:** $PROJECT_NAME

## What to do next

EOF

    if [ -n "$PROJECT_REF" ]; then
        cat >> "$BREADCRUMB_FILE" <<EOF
1. The Supabase project was NOT deleted (preserved for debugging).
2. To inspect it: \`supabase inspect db --project-ref $PROJECT_REF\`
3. When done, delete it: \`supabase projects delete $PROJECT_REF --yes\`
4. To resume the campaign from where it left off:
   \`\`\`bash
   DATABASE_URL="<connection string for $PROJECT_REF>" \\
       ./efficacy/campaign.sh
   \`\`\`
EOF
    else
        cat >> "$BREADCRUMB_FILE" <<EOF
1. No project was created — fix the issue and re-run.
2. To re-run: \`E2E_ORG_ID=$ORG_ID ./efficacy/e2e.sh\`
EOF
    fi

    effi_log "Breadcrumb written: $BREADCRUMB_FILE"
}

cleanup() {
    local exit_code=$?
    if [ -n "$CAMPAIGN_SUCCEEDED" ] && [ -n "$PROJECT_REF" ]; then
        effi_log "=== Teardown: deleting project $PROJECT_REF ==="
        if retry "delete project" "$MAX_RETRIES" "$RETRY_DELAY" \
            supabase projects delete "$PROJECT_REF" --yes; then
            effi_log "Project $PROJECT_REF deleted."
        else
            effi_log "WARNING: failed to delete project $PROJECT_REF — delete manually:"
            effi_log "  supabase projects delete $PROJECT_REF --yes"
        fi
    elif [ -z "$CAMPAIGN_SUCCEEDED" ] && [ -z "$BREADCRUMB_FILE" ] && [ $exit_code -ne 0 ]; then
        drop_breadcrumb "Unexpected exit (code $exit_code)" "unknown"
    fi
}

trap cleanup EXIT

# --- Preflight ---

effi_log "=== E2E Campaign Lifecycle ==="
effi_log "  Org:      $ORG_ID"
effi_log "  Region:   $REGION"
effi_log "  Size:     $SIZE"
effi_log "  Profile:  $(basename "$PROFILE")"
effi_log "  Timeout:  ${STATEMENT_TIMEOUT}"

effi_require supabase
effi_require psql
effi_require pgbench
effi_require jq
effi_require openssl

if [ -n "${CAMPAIGN_DRY_RUN:-}" ]; then
    effi_log "=== Dry run: skipping provisioning, forwarding to campaign.sh ==="
    "$SCRIPT_DIR/campaign.sh"
    exit 0
fi

# =========================================================================
# Phase 1: Provision
# =========================================================================

effi_log "=== Phase 1: Provision Supabase project ==="

create_project() {
    local output
    output=$(supabase projects create "$PROJECT_NAME" \
        --org-id "$ORG_ID" \
        --db-password "$DB_PASSWORD" \
        --region "$REGION" \
        --size "$SIZE" \
        --output-format json \
        --yes 2>&1) || { echo "$output" >&2; return 1; }

    local json_line ref
    json_line=$(echo "$output" | grep '^{' | head -1)
    ref=$(echo "$json_line" | jq -r '.id // empty') || true
    if [ -z "$ref" ]; then
        effi_log "FATAL: create succeeded but could not parse project ref from output."
        effi_log "  Raw output (may contain a billable project): $output"
        drop_breadcrumb \
            "supabase projects create returned OK but ref could not be parsed. Check the Supabase dashboard for orphaned projects." \
            "provision"
        exit 1
    fi
    PROJECT_REF="$ref"
    effi_log "  Project created: $PROJECT_REF"
}

if ! retry "create project" "$MAX_RETRIES" "$RETRY_DELAY" create_project; then
    drop_breadcrumb "Failed to create Supabase project after $MAX_RETRIES attempts" "provision"
    exit 1
fi

# =========================================================================
# Phase 2: Wait for readiness
# =========================================================================

effi_log "=== Phase 2: Waiting for project readiness (timeout: ${READINESS_TIMEOUT}s) ==="

POOLER_HOST="aws-0-${REGION}.pooler.${SUPABASE_DOMAIN}"
DATABASE_URL="postgresql://postgres.${PROJECT_REF}:${DB_PASSWORD}@${POOLER_HOST}:5432/postgres"
export DATABASE_URL

elapsed=0
poll_interval=10
ready=""
last_psql_err=""
while [ "$elapsed" -lt "$READINESS_TIMEOUT" ]; do
    if last_psql_err=$(psql "$DATABASE_URL" -X -q -c "SELECT 1;" 2>&1); then
        ready=1
        break
    fi
    effi_log "  Not ready yet (${elapsed}s/${READINESS_TIMEOUT}s)..."
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
done

if [ -z "$ready" ]; then
    drop_breadcrumb \
        "Project $PROJECT_REF did not become ready within ${READINESS_TIMEOUT}s. Last psql error: ${last_psql_err}" \
        "readiness"
    exit 1
fi

effi_log "  Connection verified on pooler ($POOLER_HOST)"

# =========================================================================
# Phase 3: Configure
# =========================================================================

effi_log "=== Phase 3: Configure ==="

configure_project() {
    effi_psql <<SQL
ALTER ROLE postgres SET statement_timeout = '${STATEMENT_TIMEOUT}';
CREATE EXTENSION IF NOT EXISTS pg_cron;
SQL
}

if ! retry "configure project" "$MAX_RETRIES" "$RETRY_DELAY" configure_project; then
    drop_breadcrumb "Failed to configure project $PROJECT_REF (statement_timeout / pg_cron)" "configure"
    exit 1
fi

effi_log "  statement_timeout = $STATEMENT_TIMEOUT"
effi_log "  pg_cron installed"

# Reconnect so the new statement_timeout takes effect for the session.
if ! psql "$DATABASE_URL" -X -q -c "SHOW statement_timeout;" >/dev/null 2>&1; then
    drop_breadcrumb "Post-configuration connection test failed" "configure"
    exit 1
fi

# =========================================================================
# Phase 4: Run campaign
# =========================================================================

effi_log "=== Phase 4: Run campaign ==="

run_campaign() {
    "$SCRIPT_DIR/campaign.sh"
}

if ! retry "campaign" 2 0 run_campaign; then
    drop_breadcrumb "Campaign failed after 2 attempts" "campaign"
    exit 1
fi

# =========================================================================
# Phase 5: Verify results
# =========================================================================

effi_log "=== Phase 5: Verify results ==="

read -ra FIXTURES <<< "${CAMPAIGN_FIXTURES:-oltp}"
read -ra SCENARIOS <<< "${CAMPAIGN_SCENARIOS:-steady drift}"
read -ra SEEDS <<< "${CAMPAIGN_SEEDS:-1 2 3}"
read -ra ARMS <<< "${CAMPAIGN_ARMS:-defaults expert-static pgfc-active}"

verify_ok=1
for fixture in "${FIXTURES[@]}"; do
    for scenario in "${SCENARIOS[@]}"; do
        for seed in "${SEEDS[@]}"; do
            for arm in "${ARMS[@]}"; do
                if ! effi_find_run "$arm" "$fixture" "$scenario" "$seed" >/dev/null 2>&1; then
                    effi_log "  MISSING: $arm / $fixture / $scenario / s$seed"
                    verify_ok=""
                fi
            done
        done
    done
done

if [ -z "$verify_ok" ]; then
    drop_breadcrumb "Some trial results missing from local disk — see log above" "verify"
    exit 1
fi

effi_log "  All trial results present on local disk."

# =========================================================================
# Phase 6: Success → teardown
# =========================================================================

CAMPAIGN_SUCCEEDED=1
effi_log "=== Campaign complete. Project $PROJECT_REF will be deleted on exit. ==="
