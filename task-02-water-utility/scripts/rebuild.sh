#!/bin/bash
# Rebuilds the whole lab from scratch. Passwords come from the environment.
set -e
P="/c/Program Files/PostgreSQL/18/bin/psql.exe"
export PGPASSWORD="${PGPASSWORD:?set PGPASSWORD to the postgres password}"
OPPW="${OPPW:?set OPPW to the password for district_operator}"
"$P" -U postgres -h localhost -q -c "DROP DATABASE IF EXISTS suvta" -c "DROP ROLE IF EXISTS district_operator" -c "CREATE DATABASE suvta"
"$P" -U postgres -h localhost -d suvta -q -f ../sql/p1_core.sql > p1_core.out 2>&1
"$P" -U postgres -h localhost -d suvta -q -v op_pw="$OPPW" -f ../sql/p1_rls.sql > p1_rls.out 2>&1
PGPASSWORD="$OPPW" "$P" -U district_operator -h localhost -d suvta -f ../sql/p1_rls_test.sql > p1_rls_test.out 2>&1 || true
"$P" -U postgres -h localhost -d suvta -v ON_ERROR_STOP=1 -f ../sql/p2_generate.sql > p2_generate.out 2>&1
PGPASSWORD="$PGPASSWORD" python -I run_part2.py > run_part2.log 2>&1
echo REBUILD-DONE
