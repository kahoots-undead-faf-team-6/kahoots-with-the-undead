#!/bin/sh
# Runs once, on the initial primary, when its data directory is created
# (mounted as /docker-entrypoint-initdb.d/00-replication.sh). deploy/postgres/README.md explains it.
#
# - creates the replication user (REPLICATION LOGIN) with PG_REPL_PASSWORD;
# - grants it what pg-router needs, so the router never uses the superuser:
#   pg_monitor (lag, WAL receiver), pg_promote(), ALTER SYSTEM on primary_conninfo / primary_slot_name,
#   pg_reload_conf();
# - allows replication connections with a password (pg_hba.conf).
# The standbys copy all of this with pg_basebackup, so it also holds after a failover.
#
# docker-entrypoint.sh sources this file when it is not executable: no "set -u" or "exit" here.
set -e

: "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD is required}"
repl_user="${PG_REPL_USER:-replicator}"

# Function privileges are per database: grant them in "postgres", the database pg-router connects to.
# The role, pg_monitor and the ALTER SYSTEM grants are cluster-wide.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v repl_user="$repl_user" -v repl_password="$PG_REPL_PASSWORD" <<'SQL'
CREATE ROLE :"repl_user" WITH REPLICATION LOGIN PASSWORD :'repl_password';
GRANT pg_monitor TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_promote(boolean, integer) TO :"repl_user";
GRANT EXECUTE ON FUNCTION pg_reload_conf() TO :"repl_user";
GRANT ALTER SYSTEM ON PARAMETER primary_conninfo TO :"repl_user";
GRANT ALTER SYSTEM ON PARAMETER primary_slot_name TO :"repl_user";
SQL

echo "host replication $repl_user all scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "[init-replication] created replication user $repl_user"
