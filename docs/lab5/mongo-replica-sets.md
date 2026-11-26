# MongoDB replica sets for World and Zombie (Lab 5, Grade 5)

World and Zombie keep their data in MongoDB. Since Lab 5 each of them has a **replica set of 3 members** instead of one container (`docs/lab5-contract.md` §8). The Postgres services use Vladlen's template with `pg-router` (`deploy/postgres/README.md`); MongoDB does not need a router, because replication and failover are built into it and into the driver.

| Service | Replica set | Members | Host ports (demo) |
|---|---|---|---|
| world-service | `world-rs` | `world-mongo-1`, `world-mongo-2`, `world-mongo-3` | 27011, 27013, 27014 |
| zombie-service | `zombie-rs` | `zombie-mongo-1`, `zombie-mongo-2`, `zombie-mongo-3` | 27012, 27015, 27016 |

## How it works

- **One PRIMARY, two SECONDARYs.** Writes go to the PRIMARY; the SECONDARYs copy its oplog continuously. Every member has all the data.
- **Failover.** The members ping each other every 2 s. When the PRIMARY does not answer for 10 s (`electionTimeoutMillis`), the SECONDARYs elect a new one; a majority (2 of 3) is needed, so a set of 3 survives losing any one member. A PRIMARY that is stopped cleanly (`docker stop`) steps down by itself and the election takes well under a second.
- **The services.** `MONGO_URI` lists all three members with `replicaSet=<name>`. The Node driver discovers the set, sends writes to the PRIMARY, follows it to the new one after an election and retries a failed write once (`retryWrites=true`). With `readPreference=primaryPreferred`, reads go to a SECONDARY while there is no PRIMARY. The services have no failover code of their own; they only log the change (`src/store/topology.ts` in World, `.js` in Zombie): `mongo primary found`, `mongo has no primary, waiting for an election`, `mongo primary changed`.
- **Authentication.** The members prove to each other that they belong to the set with a shared **keyFile**. `mongo-keyfile` creates a random one once in the `mongo-keys` volume (never in git), owned by mongod's user and readable only by it.
- **Start-up.** Only member 1 has `MONGO_INITDB_ROOT_*`, so only it creates the root user. `<db>-mongo-init` (`deploy/mongo/init-replica-set.sh`) runs `rs.initiate()` once, if the set is not initiated yet, and waits until there is a PRIMARY. Members 2 and 3 then copy everything from the PRIMARY, the root user included (initial sync). The services start after the init container has finished. All members have the same priority, so a member that comes back after a failover rejoins as a SECONDARY and does not force a second election.
- **Old host name.** `world-mongo` / `zombie-mongo` are kept as network aliases of member 1 for clients that still use the Lab 4 name; new clients should list the three members.

## Measured

`world-service` (this branch) against `world-rs`, a `GET /rooms` and a `POST /rooms` every 0.5 s:

| What was done to the PRIMARY | Reads (`GET`) | Writes (`POST`) | New PRIMARY after |
|---|---|---|---|
| `docker stop` (clean step-down) | 80 / 80 answered `200` | 80 / 80 answered `201` | under 1 s |
| `docker kill` (crash) | every one answered `200` (served by a SECONDARY) | 1 answered `408` (the service's 5 s limit), the next ones waited and succeeded | about 10 s |

Both are under the 15 s of the shared demo. A crash costs about 10 s of writes because the members wait 10 s before they declare the PRIMARY dead; `MONGO_SERVER_SELECTION_MS` (default 5 000) is how long a single query waits for a PRIMARY before it fails.

## Demo

```bash
C="docker compose -f deploy/docker-compose.yml --env-file deploy/.env"
$C exec world-mongo-1 mongosh -u root -p "$WORLD_MONGO_PASSWORD" --authenticationDatabase admin --quiet \
  --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'      # PRIMARY + 2 SECONDARY
$C kill world-mongo-1                                                   # or stop: a clean step-down
curl -s localhost:8080/world/rooms -H "Authorization: Bearer $T"        # still 200 (from a SECONDARY)
$C logs world-service | grep "mongo primary"                            # mongo primary changed ... world-mongo-2
$C start world-mongo-1                                                  # rejoins as SECONDARY, catches up from the oplog
```

**After a full `down -v`**, everything is created again from scratch. Moving from the Lab 4 single `world-mongo` volume to the replica set starts with empty databases, and `SEED_ON_START=true` fills them again.
