#!/usr/bin/env bash
# Run the documentation's doctests: every ```sql block marked `<!-- doctest -->`
# (see scripts/extract-doctests.py) is executed against a fresh install of both
# extensions and must succeed. Each block runs isolated in a rolled-back transaction,
# so doctests are independent and leave no state. "The example no longer works" => red.
#
#   scripts/run-doctests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export PG_VERSION="${PG_DOCTEST_VERSION:-17}"
COMPOSE=(docker compose
         -f docker-compose.yml
         -f pgfc_observe/docker-compose.yml
         -f pgfc_govern/docker-compose.yml)

tmp="$(mktemp -d)"
cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build >/dev/null

echo "Waiting for database to become healthy..." >&2
status=""
for _ in $(seq 1 60); do
  cid=$("${COMPOSE[@]}" ps -q db)
  status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] || { echo "database never became healthy" >&2; exit 1; }

PSQL=(psql -U postgres -d pgfc_test -v ON_ERROR_STOP=1 -X -q)
"${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/pgfc_observe/install.sql >/dev/null
"${COMPOSE[@]}" exec -T db "${PSQL[@]}" -f /sql/pgfc_govern/install.sql  >/dev/null

count="$(python3 scripts/extract-doctests.py . "$tmp")"
echo "found ${count} doctest block(s)" >&2

fail=0
for sqlf in "$tmp"/*.sql; do
  [ -e "$sqlf" ] || break          # no doctests
  origin="$(head -1 "$sqlf")"
  if printf 'BEGIN;\n%s\nROLLBACK;\n' "$(cat "$sqlf")" \
       | "${COMPOSE[@]}" exec -T db "${PSQL[@]}" >/dev/null 2>"$tmp/err"; then
    echo "ok   ${origin}" >&2
  else
    echo "FAIL ${origin}" >&2
    sed 's/^/       /' "$tmp/err" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || { echo "doctests failed" >&2; exit 1; }
echo "all doctests passed" >&2
