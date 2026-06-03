#!/usr/bin/env bash
# Prove the documented UPGRADE path end to end. Install the latest release tag's extensions
# (the shape a real operator is running), then apply the current install.sql over them — the
# project's stated upgrade path, "re-running install.sql is the upgrade path" — and run the
# full pgTAP suite against the upgraded database to prove it converged to the current schema.
#
#   ./upgrade.sh                          # all supported versions (15 16 17 18)
#   ./upgrade.sh 17                       # a single version (fast dev loop)
#   PGFC_UPGRADE_FROM=v0.2.0 ./upgrade.sh # upgrade from a specific ref instead of the latest tag
#
# WHY this exists alongside test.sh: test.sh only does a FRESH install plus an install-twice
# idempotency pass, so it never exercises an OLD-shape -> NEW-shape migration — the one-time
# destructive recreates, the DROP of removed/return-type-changed functions, the additive
# ALTERs. That blind spot let FMEA-001's orphaned and retyped functions reach a "Verified"
# state before a manual upgrade run caught them; this gate closes it.
#
# BASELINE = the latest release tag (git describe), so this encodes a SUPPORT POLICY: the
# current code must be upgradeable, in a single install.sql re-run, from the latest release.
# An operator jumps release -> HEAD directly and never visits the intermediate per-PR states,
# so the jump is NOT decomposable into base-branch hops — the real jump is what must be tested.
# The jump grows until a new tag is cut, which advances the baseline automatically. When a
# change legitimately cannot support an old shape, the escape hatch is to cut a new release tag
# (which moves the baseline forward), NOT to weaken this test.
set -euo pipefail
cd "$(dirname "$0")"

VERSIONS=("$@")
if [ ${#VERSIONS[@]} -eq 0 ]; then
  VERSIONS=(15 16 17 18)
fi

FROM_REF="${PGFC_UPGRADE_FROM:-$(git describe --tags --abbrev=0)}"
echo "Upgrade baseline: ${FROM_REF} -> HEAD (working tree)"

COMPOSE=(docker compose
         -f docker-compose.yml
         -f pgfc_observe/docker-compose.yml
         -f pgfc_govern/docker-compose.yml)
PSQL=(psql -U postgres -d pgfc_test -v ON_ERROR_STOP=1 -X -q)

overall=0
for v in "${VERSIONS[@]}"; do
  echo "============================================================"
  echo "  PostgreSQL ${v}  —  upgrade ${FROM_REF} -> HEAD"
  echo "============================================================"
  export PG_VERSION="$v"

  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  "${COMPOSE[@]}" up -d --build

  echo "Waiting for database to become healthy..."
  status=""
  for _ in $(seq 1 60); do
    cid=$("${COMPOSE[@]}" ps -q db)
    status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "starting")
    [ "$status" = "healthy" ] && break
    sleep 2
  done
  if [ "$status" != "healthy" ]; then
    echo "PG ${v}: database never became healthy" >&2
    "${COMPOSE[@]}" logs db | tail -30 >&2 || true
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    overall=1
    continue
  fi

  rc=0
  # Install the BASELINE (release-tag) shape first — observe then govern (govern reads observe),
  # piped from `git show` so no checkout of the old tree is needed. Then apply the CURRENT
  # install.sql over it: each extension TWICE, to prove the upgrade AND that the post-upgrade
  # re-run is still idempotent (the recreate / DROP ... CASCADE / view-restore logic is exactly
  # the re-run-sensitive kind). observe's destructive recreate CASCADE-drops govern's
  # cross-schema views, so govern is applied AFTER observe to restore them. Finally run the
  # current pgTAP suite against the upgraded database: if the schema converged, it all passes.
  "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pgtap;" \
    && git show "${FROM_REF}:pgfc_observe/install.sql" | "${COMPOSE[@]}" exec -T db "${PSQL[@]}" \
    && git show "${FROM_REF}:pgfc_govern/install.sql"  | "${COMPOSE[@]}" exec -T db "${PSQL[@]}" \
    && "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/pgfc_observe/install.sql \
    && "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/pgfc_observe/install.sql \
    && "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/pgfc_govern/install.sql \
    && "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/pgfc_govern/install.sql \
    && "${COMPOSE[@]}" exec -T db bash -c \
         "pg_prove -U postgres -d pgfc_test --pset pager=off \
            /sql/pgfc_observe/tests/*.sql /sql/pgfc_govern/tests/*.sql" \
    || rc=$?

  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

  if [ "$rc" -ne 0 ]; then
    echo "PG ${v}: UPGRADE FAILED (rc=$rc)"
    overall=1
  else
    echo "PG ${v}: UPGRADE PASSED"
  fi
done

exit "$overall"
