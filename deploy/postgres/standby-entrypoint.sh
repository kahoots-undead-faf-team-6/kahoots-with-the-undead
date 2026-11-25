#!/bin/sh
# Entrypoint of every node of a replicated PostgreSQL database (<db>-1, <db>-2, <db>-3).
# deploy/postgres/README.md explains the template.
#
# - The data directory already exists: start PostgreSQL as usual. A standby keeps its standby.signal,
#   a primary stays a primary (pg-router fences an old primary that comes back).
# - It is empty and another node is a primary: clone it with
#     pg_basebackup -R -X stream -C -S <slot>
#   (-R writes standby.signal + primary_conninfo, -C -S creates this node's replication slot), then start
#   as a standby. This is also how a fenced old primary comes back: delete its volume and start it again.
# - It is empty, no node is a primary and PG_INITIAL_PRIMARY=true: this is the first start, so initialise
#   the database as usual (docker-entrypoint.sh runs init-replication.sh and the seed scripts once).
# - Otherwise wait for a primary.
#
# Environment: PG_NODE_NAME (this container), PG_NODES (host:port,host:port,...), PG_REPL_PASSWORD,
# PG_REPL_USER (default replicator), PG_INITIAL_PRIMARY (true on <db>-1 only).
set -eu

: "${PG_NODE_NAME:?PG_NODE_NAME is required}"
: "${PG_NODES:?PG_NODES is required}"
: "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD is required}"
REPL_USER="${PG_REPL_USER:-replicator}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
export PGDATA
SLOT=$(printf '%s' "$PG_NODE_NAME" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g')

log() { echo "[standby-entrypoint] $PG_NODE_NAME: $*"; }

# Prints "host port" of a node (not this one) that answers and is not in recovery.
find_primary() {
  for node in $(printf '%s' "$PG_NODES" | tr ',' ' '); do
    host="${node%%:*}"
    port="${node#*:}"
    [ "$port" = "$node" ] && port=5432
    [ "$host" = "$PG_NODE_NAME" ] && continue
    writable=$(PGPASSWORD="$PG_REPL_PASSWORD" psql -X -tA \
      "host=$host port=$port user=$REPL_USER dbname=postgres connect_timeout=2" \
      -c "SELECT NOT pg_is_in_recovery()" 2>/dev/null || true)
    if [ "$writable" = "t" ]; then
      echo "$host $port"
      return 0
    fi
  done
  return 1
}

if [ -s "$PGDATA/PG_VERSION" ]; then
  log "data directory exists, starting PostgreSQL"
  exec docker-entrypoint.sh "$@"
fi

while :; do
  if primary=$(find_primary); then
    host="${primary% *}"
    port="${primary#* }"
    log "cloning the primary $host:$port (slot $SLOT)"
    # A slot left by an earlier clone of this node would make -C fail: drop it if nothing uses it.
    PGPASSWORD="$PG_REPL_PASSWORD" psql -X -q "host=$host port=$port user=$REPL_USER dbname=postgres" \
      -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$SLOT' AND NOT active" >/dev/null
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    # The password is written into primary_conninfo by -R; pg-router rewrites it after a failover.
    su-exec postgres pg_basebackup \
      -d "host=$host port=$port user=$REPL_USER password=$PG_REPL_PASSWORD application_name=$PG_NODE_NAME" \
      -D "$PGDATA" -R -X stream -C -S "$SLOT"
    log "clone done, starting as a standby"
    exec docker-entrypoint.sh "$@"
  fi
  if [ "${PG_INITIAL_PRIMARY:-false}" = "true" ]; then
    log "no primary found and this is the initial primary: initialising the database"
    exec docker-entrypoint.sh "$@"
  fi
  log "waiting for a primary to clone"
  sleep 2
done
