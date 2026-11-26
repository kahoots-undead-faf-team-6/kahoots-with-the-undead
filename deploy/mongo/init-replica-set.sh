#!/usr/bin/env bash
# Lab 5 (Mihai): initiates a MongoDB replica set once, then waits until it has a PRIMARY.
# Run by world-mongo-init and zombie-mongo-init in deploy/docker-compose.yml (docs/lab5/mongo-replica-sets.md).
#
#   RS_NAME         world-rs
#   RS_MEMBERS      world-mongo-1:27017,world-mongo-2:27017,world-mongo-3:27017 (the first one has the root user)
#   MONGO_USER      root user created on the first member by MONGO_INITDB_ROOT_USERNAME
#   MONGO_PASSWORD
#
# Running it again is safe: an initiated set is left as it is. All members get the same priority, so
# after a failover the old PRIMARY comes back as a SECONDARY and does not force a second election.
set -euo pipefail

: "${RS_NAME:?}" "${RS_MEMBERS:?}" "${MONGO_USER:?}" "${MONGO_PASSWORD:?}"
IFS=',' read -ra MEMBERS <<< "$RS_MEMBERS"
FIRST="${MEMBERS[0]}"
AUTH=(--quiet --username "$MONGO_USER" --password "$MONGO_PASSWORD" --authenticationDatabase admin)

log() { echo "{\"service\":\"${RS_NAME}-init\",\"level\":\"$1\",\"msg\":\"$2\"}"; }

for _ in $(seq 1 60); do
  if mongosh --host "$FIRST" "${AUTH[@]}" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then break; fi
  sleep 2
done

CONFIG="{ _id: '$RS_NAME', members: ["
for i in "${!MEMBERS[@]}"; do
  CONFIG+="{ _id: $i, host: '${MEMBERS[$i]}' },"
done
CONFIG="${CONFIG%,}] }"

mongosh --host "$FIRST" "${AUTH[@]}" --eval "
  try {
    const status = rs.status();
    print('replica set ' + status.set + ' already initiated, ' + status.members.length + ' members');
  } catch (err) {
    if (err.codeName !== 'NotYetInitialized') throw err;
    rs.initiate($CONFIG);
    print('rs.initiate done for $RS_NAME');
  }"

for _ in $(seq 1 60); do
  primary=$(mongosh --host "$FIRST" "${AUTH[@]}" --eval 'print(db.hello().primary || "")' 2>/dev/null || true)
  if [ -n "$primary" ]; then
    log info "PRIMARY is $primary"
    exit 0
  fi
  sleep 2
done
log error "no PRIMARY after 120 s"
exit 1
