#!/usr/bin/env bash
# Runs the SQL checks in db/tests/ against the migrated database. Rolls back.
set -euo pipefail
CONTAINER="${ORACLE_CONTAINER:-suraksha-oracle}"
CONN="${DB_CONN:-suraksha/suraksha@//localhost:1521/FREEPDB1}"
for f in "$(cd "$(dirname "$0")/tests" && pwd)"/*.sql; do
  echo "== $(basename "$f")"
  { echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"; cat "$f"; } | docker exec -i "$CONTAINER" sqlplus -S -L "$CONN"
done
