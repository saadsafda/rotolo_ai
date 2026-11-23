#!/usr/bin/env bash
# Spins up a throwaway local Postgres, applies Supabase stubs + migrations, runs schema tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rotolo-pg.XXXXXX")"
PORT="${PGTEST_PORT:-55432}"
cleanup() { pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust --locale=C -E UTF8 >/dev/null
# TCP on loopback (unix-socket paths under long temp dirs exceed the OS limit).
pg_ctl -D "$TMP/data" -o "-p $PORT -k '' -c listen_addresses=127.0.0.1" -l "$TMP/log" -w start >/dev/null \
  || { cat "$TMP/log"; exit 1; }
PSQL=(psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q)

"${PSQL[@]}" -f "$HERE/supabase_stubs.sql"
for f in "$ROOT"/migrations/*.sql; do "${PSQL[@]}" -f "$f"; done
"${PSQL[@]}" -f "$HERE/schema_test.sql"
