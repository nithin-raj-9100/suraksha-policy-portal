#!/usr/bin/env bash
# Applies db/migrations/V*.sql in order, once each, as the SURAKSHA user.
set -euo pipefail

CONTAINER="${ORACLE_CONTAINER:-suraksha-oracle}"
CONN="${DB_CONN:-suraksha/suraksha@//localhost:1521/FREEPDB1}"
DIR="$(cd "$(dirname "$0")/migrations" && pwd)"

sql() { docker exec -i "$CONTAINER" sqlplus -S -L "$CONN"; }

sql <<'SQL' >/dev/null
WHENEVER SQLERROR EXIT FAILURE
DECLARE n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM USER_TABLES WHERE TABLE_NAME = 'SCHEMA_MIGRATIONS';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLE SCHEMA_MIGRATIONS (VERSION VARCHAR2(200) PRIMARY KEY, APPLIED_AT TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL)';
  END IF;
END;
/
EXIT
SQL

for f in "$DIR"/V*.sql; do
  v="$(basename "$f")"
  applied="$(printf "SET HEADING OFF FEEDBACK OFF PAGESIZE 0\nSELECT COUNT(*) FROM SCHEMA_MIGRATIONS WHERE VERSION = '%s';\nEXIT\n" "$v" | sql | tr -d '[:space:]')"
  if [ "$applied" = "1" ]; then
    echo "skip   $v"
    continue
  fi
  echo "apply  $v"
  {
    echo "WHENEVER SQLERROR EXIT FAILURE ROLLBACK"
    echo "SET DEFINE OFF"
    echo "SET SERVEROUTPUT ON"
    echo "SET FEEDBACK ON"
    cat "$f"
    echo
    echo "INSERT INTO SCHEMA_MIGRATIONS (VERSION) VALUES ('$v');"
    echo "COMMIT;"
    echo "EXIT"
  } | sql || { echo "FAILED $v" >&2; exit 1; }
done
echo "migrations up to date"
