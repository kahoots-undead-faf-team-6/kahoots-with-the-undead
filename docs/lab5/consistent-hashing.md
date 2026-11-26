# Consistent hashing and the gateway cache (Lab 5, Grade 7)

The gateway keeps its cache in **3 Valkey nodes** and decides itself which node holds each key, with a **consistent hashing ring** written in the gateway: `services/gateway/app/cache/ring.py`. This page explains why a ring, how ours works, what the measurements show, and how it differs from **Redis Cluster**. The cache itself (what is cached, keys, invalidation) is in `docs/lab5-contract.md` §7 and the gateway README, section *Cache*.

## 1. The problem: `hash(key) % N`

With N nodes, the simplest placement is `node = hash(key) % N`. It spreads keys evenly, but **almost every key changes node when N changes**: a key stays only if `hash % N == hash % (N±1)`. Going from 3 to 4 nodes moves about 3/4 of the keys; losing one of 3 nodes moves about 2/3.

For a cache, a key that moved is a miss: the data is still in the old node, but nobody looks there. So one node dying, or one node being added, empties most of the cache at once, and every service behind the gateway gets the full load at the same moment.

## 2. The ring

Consistent hashing puts **nodes and keys on the same circle** of hash values, 0 to 2^64 − 1 for us:

1. Every node is hashed to a position on the circle.
2. Every key is hashed to a position on the circle.
3. A key belongs to the **first node clockwise** from its position, wrapping from the end of the circle back to 0.

When a node is **added**, it takes only the keys between its position and the node before it: about 1/N of the keys, all moving to the new node. When a node is **removed**, only its own keys move, to the next node clockwise. Every other key stays where it was.

### Virtual nodes

With one point per node, three random points cut the circle into three arcs of very different lengths, so one node can own most of the keys. The fix is **virtual nodes**: each node puts many points on the circle (`"cache-1:6379#0"`, `"cache-1:6379#1"`, ...). Many small arcs per node average out to an even share, and when a node leaves, its keys spread over **all** remaining nodes instead of falling on one neighbour.

### Our implementation

| Choice | Value | Why |
|---|---|---|
| Hash | first 8 bytes of MD5, as an unsigned 64-bit integer | the same in every process and after a restart (Python's `hash()` is salted per process); evenly spread. MD5 is used only for placement, not for security |
| Virtual nodes | `CACHE_VNODES`, default **160** per node | even shares (see §3), still only 480 points to search |
| Lookup | sorted list of points + binary search (`bisect`) | O(log P), about 0.6 µs per key measured |
| Node failure | 3 failed calls in a row (`CACHE_FAIL_THRESHOLD`) → `remove_node`; tried again after 10 s (`CACHE_RETRY_S`) | a dead node's keys move to the next node clockwise; the rest keep hitting |
| Where the ring lives | in the gateway (the client) | the Valkey nodes are plain, independent servers; they know nothing of each other |

```python
def node_for(self, key):
    index = bisect.bisect_right(self._points, hash64(key))   # first point clockwise
    if index == len(self._points):                           # past the last point: wrap to 0
        index = 0
    return self._owner[self._points[index]]
```

## 3. Measurements

100 000 keys of the form `resp:v0:world-service:/rooms/r{i}?`, nodes `cache-1..3:6379` (reproduce them with `pytest tests/test_ring.py` in the gateway).

**Distribution over 3 nodes, by virtual nodes per node:**

| Virtual nodes | cache-1 | cache-2 | cache-3 |
|---|---|---|---|
| 1 | 4.2 % | 15.6 % | 80.2 % |
| 10 | 44.7 % | 13.9 % | 41.4 % |
| **160** | **34.7 %** | **33.0 %** | **32.3 %** |

**Keys that change node:**

| Change | `hash % N` | Ring (160 vnodes) | Ideal |
|---|---|---|---|
| 3 → 4 nodes (one added) | 74.8 % | **24.3 %** | 25 % |
| 3 → 2 nodes (one lost) | 66.4 % | **33.0 %** | 33.3 % |

On the ring, the keys that move go **only** to the new node (when adding) or **only** away from the lost node (when removing); `test_adding_a_node_moves_about_a_quarter_of_the_keys_and_only_to_it` and `test_removing_a_node_moves_only_its_keys` check it.

**With real Valkey** (3 containers, 3 000 keys): 1 047 / 991 / 962 keys per node. After `docker stop cache-2`, the gateway took the node out of the ring after 3 failures, and **2 009 of 3 000 keys were still hits**: exactly the keys of the two live nodes. No request failed; a call to a dead node costs at most 50 ms (`CACHE_TIMEOUT_MS`), and once the node is out of the ring, none.

## 4. Our ring vs Redis Cluster

Redis Cluster (and Valkey Cluster, the same design) also shards keys, but not with a ring.

| | Our ring (gateway) | Redis / Valkey Cluster |
|---|---|---|
| Key space | a circle of 2^64 positions; ownership = the arcs between points | **16 384 fixed hash slots**; slot = `CRC16(key) mod 16384` |
| Who owns what | computed from the node list: every node puts 160 points on the circle | an explicit **slot → node map**, stored in every node; an operator assigns slots (e.g. 5 461 / 5 461 / 5 462 for 3 nodes) |
| Who decides where a key goes | the **client** (the gateway), alone | the **cluster**; a client that asks the wrong node gets `MOVED <slot> <node>` and follows it; smart clients cache the slot map |
| Adding a node | automatic: its points take ~1/N of the keys from all nodes at once; those keys are simply misses | manual resharding: slots are moved **with their data** (`MIGRATE`) one by one; during the move the client gets `ASK` redirects; no data is lost |
| A node dies | its keys move to the next node clockwise and start empty (misses); after 10 s it is tried again | each primary has **replicas**; the others vote and promote a replica (failover), the data survives. Without a replica its slots are down (by default the whole cluster refuses writes, `cluster-require-full-coverage`) |
| Keys used together | no grouping: two keys may land on different nodes | **hash tags**: only the `{...}` part is hashed, so `{player:1}:inv` and `{player:1}:xp` share a slot; multi-key commands work only inside one slot |
| Nodes know each other | no | yes: cluster bus, gossip, failure detection, configuration epochs |
| Cost | ~100 lines in the gateway, plain Valkey containers | a cluster to set up (`--cluster create`), at least 3 primaries (+ replicas), a cluster-aware client |
| Fits | a **cache**: losing a node's keys only means misses | a **data store**: keys must not be lost and must survive resharding |

**Why we built the ring.** Our cache only holds copies: every value can be fetched again from the service behind it. So the thing that matters is that a node leaving or joining invalidates as little as possible, and that the gateway never waits for a cache. A client-side ring gives exactly that, with independent nodes and no cluster to operate. Redis Cluster's strengths (no data loss on resharding, replica failover, multi-key operations through hash tags) are the strengths of a database. A cache does not need them, and they would cost a cluster setup and slower failure handling (an election instead of skipping the node in 3 calls).

**What the ring does not do.** There are no replicas: a dead node's keys are gone until they are fetched again. Nothing moves data when a node joins: the new node starts empty and fills through misses. Two gateways with different node lists would disagree on placement, so `CACHE_NODES` must be the same for every gateway instance (we run one).

## 5. Demo

```bash
ADMIN=$(curl -s -X POST localhost:8080/auth/token -H 'Content-Type: application/json' \
  -d "{\"playerId\":\"admin\",\"role\":\"admin\",\"adminKey\":\"$ADMIN_KEY\"}" | jq -r .accessToken)
curl -s localhost:8080/admin/cache/ring -H "Authorization: Bearer $ADMIN" | jq     # 3 nodes, ringShare ~0.33 each, keys per node
curl -s "localhost:8080/admin/cache/locate?path=/world/rooms" -H "Authorization: Bearer $ADMIN" | jq
docker compose -f deploy/docker-compose.yml stop cache-2
# requests keep answering 200; after 3 failures cache-2 is "inRing": false and its share goes to the others
curl -s localhost:8080/admin/cache/ring -H "Authorization: Bearer $ADMIN" | jq '.state, .nodesInRing'
docker compose -f deploy/docker-compose.yml start cache-2   # back in the ring after CACHE_RETRY_S (10 s)
```

Grafana, dashboard **Overview**, row **Cache (Lab 5)**: hit ratio, operations per node and result, nodes in the ring.

## Sources

- D. Karger et al., *Consistent Hashing and Random Trees*, STOC 1997: the original ring and virtual copies of each node.
- G. DeCandia et al., *Dynamo: Amazon's Highly Available Key-value Store*, SOSP 2007, §4.2: a ring with virtual nodes in production.
- Redis documentation, *Scale with Redis Cluster* and the *Redis Cluster specification*: hash slots, `CRC16 mod 16384`, `MOVED` / `ASK`, hash tags, replica failover.
