#!/usr/bin/env bash
# Run the pgfc_observe pgTAP suite against one or more PostgreSQL versions.
#
#   ./test.sh            # all supported versions (15 16 17 18)
#   ./test.sh 17         # a single version (fast dev loop)
#   ./test.sh 16 17      # a subset
#
# Each version is built fresh (postgres + pgTAP), install.sql is applied, and the
# tests/ directory is run with pg_prove inside the container.
set -euo pipefail
cd "$(dirname "$0")"

VERSIONS=("$@")
if [ ${#VERSIONS[@]} -eq 0 ]; then
  VERSIONS=(15 16 17 18)
fi

COMPOSE=(docker compose -f docker-compose.yml -f pgfc_observe/docker-compose.yml)
PSQL=(psql -U postgres -d pgfc_test -v ON_ERROR_STOP=1 -X -q)

overall=0
for v in "${VERSIONS[@]}"; do
  echo "============================================================"
  echo "  PostgreSQL ${v}"
  echo "============================================================"
  export PG_VERSION="$v"

  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  "${COMPOSE[@]}" up -d --build

  echo "Waiting for database to become healthy..."
  cid=""
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
  # pgTAP must be available for the tests; install.sql is the extension under test.
  "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pgtap;" \
    && "${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/install.sql \
    && "${COMPOSE[@]}" exec -T db bash -c \
         "pg_prove -U postgres -d pgfc_test --pset pager=off /sql/tests/*.sql" \
    || rc=$?

  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

  if [ "$rc" -ne 0 ]; then
    echo "PG ${v}: FAILED (rc=$rc)"
    overall=1
  else
    echo "PG ${v}: PASSED"
  fi
done

exit "$overall"
