# Lab 4 – Breaking and Brokering: shared contract

Every service follows these rules, whatever its language. If something here and a service README disagree, this file wins; change it here first, in a PR to `development`. The Lab 3 contract (`docs/lab3-contract.md`) still holds wherever this file says nothing.

Version for every image this lab: **`4.0.0`** (and `latest`).

## 1. Message Broker

The **Message Broker** is a new service written in the banned language (**Python 3.12**), repo `kahoots-undead-faf-team-6/message-broker`, submodule `services/message-broker`, image **`alexandrubujor1/message-broker:4.0.0`** and `:latest`.

- **`grpcio`** for the broker API, **FastAPI** for the admin HTTP API.
- Same language as `gateway` and `service-discovery`, so the Lab 3 load balancer and circuit breaker are **moved** from the gateway, not rewritten.

| Port (inside Docker) | Protocol | Use |
|---|---|---|
| `50051` | gRPC | `message-broker:50051`, the `Broker` service (§2) |
| `8600` | HTTP | admin API (§6), published on `localhost:8600` for the demo |

The broker registers itself in SD as **`message-broker`** with the Lab 3 register / heartbeat / deregister rules (Lab 3 §5).

## 2. gRPC API

The source of truth is **`proto/kahoots/broker/v1/broker.proto` in the `message-broker` repo**. Every service copies it into its own repo (`proto/` folder). The copy below must stay identical to it.

| RPC | Implemented by | Called by |
|---|---|---|
| `Broker.Call(Envelope) → Reply` | the broker | gateway, any service (request/response) |
| `Broker.Publish(Event) → PublishAck` | the broker | any service (fire-and-forget event) |
| `Endpoint.Handle(Envelope) → Reply` | **every** service, on its `GRPC_PORT` | the broker |
| `Endpoint.Deliver(Event) → DeliveryAck` | **every** service, on its `GRPC_PORT` | the broker |

```proto
syntax = "proto3";
package kahoots.broker.v1;

// One request/response, Gateway->Service or Service->Service.
message Envelope {
  string request_id      = 1; // X-Request-Id, passed on everywhere
  string source_service  = 2; // "gateway", "exam-service", ...
  string source_instance = 3;
  string target_service  = 4; // queue name = service name, e.g. "world-service"
  string method          = 5; // GET, POST, PUT, PATCH, DELETE
  string path            = 6; // path inside the service, e.g. "/rooms/r1?x=1"
  map<string, string> headers = 7; // X-User-Id, X-User-Role, Idempotency-Key, ...
  bytes body             = 8; // JSON, UTF-8
  int32 timeout_ms       = 9;
}
message Reply {
  int32 status       = 1; // HTTP status code
  map<string, string> headers = 2;
  bytes body         = 3;
  string instance_id = 4; // the instance that answered
}
// One fire-and-forget event on a topic.
message Event {
  string event_id        = 1; // UUID, handlers are idempotent on it
  string topic           = 2; // e.g. "exam.passed"
  string source_service  = 3;
  string source_instance = 4;
  string request_id      = 5;
  bytes payload          = 6; // JSON, UTF-8
  string occurred_at     = 7; // ISO 8601 UTC
}
message PublishAck { string event_id = 1; repeated string subscribers = 2; }
message DeliveryAck { bool ok = 1; string error = 2; }

// Implemented by the Message Broker (message-broker:50051).
service Broker {
  rpc Call(Envelope) returns (Reply);
  rpc Publish(Event) returns (PublishAck);
}
// Implemented by EVERY service (its own GRPC_PORT, default 50051).
service Endpoint {
  rpc Handle(Envelope) returns (Reply);
  rpc Deliver(Event) returns (DeliveryAck);
}
```

## 3. Two kinds of queues

| | Subscriber-based | Topic-based |
|---|---|---|
| Used for | Gateway → Service and Service → Service **requests** | Service → Service **events** |
| RPC | `Broker.Call` | `Broker.Publish` |
| Queue name | the target service name (`world-service`) | the topic (`exam.passed`) |
| Caller knows the receiver? | **yes**, it names `target_service` | **no**, the publisher does not know who listens |
| Subscribers | the target's `UP` instances in SD | every service that listed the topic at SD registration (`"topics": [...]`) |
| Delivered to | **one** instance (load balancer + circuit breaker), its `Reply` goes back to the caller | **once to every** subscribing service, to **one** of its instances (competing consumers) |

Rules:
- **Gateway mapping.** `/<prefix>/...` → `Broker.Call` with `target_service = "<prefix>-service"` and `path = "/..."`. Example: `GET /world/rooms/r1` → `world-service`, `/rooms/r1`.
- **Idempotency.** Event handlers are idempotent on `event_id`: the broker delivers at least once (§9).

## 4. Topic catalog

Name = `<publisher>.<event in past tense>`, payload = JSON (UTF-8).

| Topic | Publisher | Subscribers |
|---|---|---|
| `exam.passed` | exam-service | world-service (unlock wing), player-service (achievement/XP) |
| `world.wing-unlocked` | world-service | game-service |
| `resource.depleted` | resource-service | world-service, game-service |
| `base.upgraded` | base-service | player-service |
| `item.crafted` | crafting-service | player-service |
| `player.leveled-up` | player-service | crafting-service, base-service |
| `game.session-ended` | game-service | player-service |
| `zombie.type-changed` | zombie-service | game-service |

**A new topic is first added as a row in this table.**

## 5. Service Discovery changes

| Method | Path | Answer |
|---|---|---|
| POST | `/register` | also accepts `"topics": ["exam.passed", ...]` and `metadata.grpcPort` |
| GET | `/topics` | `{"topics": {"exam.passed": ["player-service","world-service"]}}` |
| GET | `/topics/{topic}/services` | `{"topic": "...", "services": {"world-service": [instance, ...]}}`: **`UP` instances only**, like `GET /services/{name}` |
| GET | `/prometheus/targets` | Prometheus `http_sd` JSON with every `UP` instance |

## 6. Broker admin HTTP (port 8600)

| Method | Path | Answer |
|---|---|---|
| GET | `/health` | `200 {"status":"ok","service":"message-broker"}` |
| GET | `/status` | the Lab 3 status format + `activeThreads`, `queues`, `dlqSize` |
| GET | `/metrics` | Prometheus text format |
| GET | `/topics` | every known topic with subscribers and counters |
| GET | `/queues` | every service queue and every (topic, service) delivery queue |
| GET | `/dlq` | dead letters |
| GET | `/dlq/{id}` | one dead letter |
| POST | `/dlq/{id}/retry` | put it back in its queue |
| DELETE | `/dlq/{id}` | drop it |

## 7. Every service: Lab 4 changes

Each owner does these in their own two services.

- **Endpoint server.** Runs a gRPC server implementing `kahoots.broker.v1.Endpoint` on `GRPC_PORT` (default `50051`).
  - `Handle(Envelope)` runs the request through the service's own HTTP routes (in-process, or loopback to `127.0.0.1:PORT`) and returns the `Reply`.
  - `Deliver(Event)` runs the topic handler.
- **Calls** other services **only** with `Broker.Call` (`BROKER_GRPC_URL=message-broker:50051`). No more `http://gateway:8081/...` anywhere.
- **Events** are fired with `Broker.Publish`, instead of HTTP `POST` notifications.
- **Registration** in SD adds `metadata.grpcPort` and the service's `topics`.
- **`GET /metrics`** in Prometheus format: `http_requests_total{method,route,status}`, `http_request_duration_seconds` (histogram), `inflight_requests`, `service_load`.
- **Log file.** Every JSON log line is **also** written to `$LOG_DIR/<instanceId>.log` when `LOG_DIR` is set (shared Docker volume `logs`, mounted at `/var/log/kahoots`).
- **Internal routes.** Each service lists the routes only other services call in §12; the gateway blocks them for users (`404`).
- **Headers** `X-Request-Id`, `X-User-Id`, `X-User-Role` travel inside `Envelope.headers`.

## 8. Broker module boundaries

So Alexandru and Vladlen can work in parallel without conflicts:

| File | What | Owner |
|---|---|---|
| `app/grpc_server.py` | `Broker` gRPC service + `ThreadPerRequestExecutor` | Alexandru |
| `app/router.py` | `Call` + `Publish` routing, fan-out to subscriber services | Alexandru |
| `app/topics.py` | topic registry + `GET /topics` | Alexandru |
| `app/store.py` | `QueueStore` interface + `InMemoryStore` / `SqliteStore` | Alexandru / Vladlen |
| `app/balancer.py` | `Balancer.pick(service, instances, exclude) -> instance` | Vladlen |
| `app/breaker.py` | per-instance circuit breaker, remove mode | Vladlen |
| `app/dlq.py` | dead letter channel + `/dlq` endpoints | Vladlen |

## 9. Reliability (Grades 8–9)

- **Durable events.** Events are written to SQLite (`BROKER_DB_PATH=/data/broker.db`, volume `broker-data`) **before** `Publish` returns. One delivery row per (event, subscriber service). At-least-once.
- **Retry.** Backoff 1, 2, 4, 8, 16 s. After `MAX_DELIVERY_ATTEMPTS` (5) the delivery goes to the **dead letter channel** with the reason.
- **Failed calls.** A `Call` that no instance could serve is also written to the DLQ (kind `"call"`).
- **HA reroute.** After a breaker trips on an instance, the broker reroutes to another instance:
  - always on `UNAVAILABLE` / connection refused;
  - on timeout or `5xx` only for `GET`/`PUT`/`DELETE`, or for requests carrying an `Idempotency-Key` header;
  - at most `MAX_REROUTES` (2) times.
- **Load balancing.** `LB_STRATEGY=least-load` (default) or `round-robin`. Load = SD heartbeat `load` + the broker's own in-flight count per instance; ties → round-robin.

## 10. Environment variables

| Variable | Default | Who | Meaning |
|---|---|---|---|
| `BROKER_GRPC_URL` | `message-broker:50051` | every service | where `Broker.Call` / `Publish` go |
| `GRPC_PORT` | `50051` | every service + broker | the gRPC server port |
| `LOG_DIR` | `/var/log/kahoots` in compose | every service + broker | also write logs to `$LOG_DIR/<instanceId>.log` |
| `BROKER_DB_PATH` | `/data/broker.db` | broker | SQLite file |
| `MAX_DELIVERY_ATTEMPTS` | `5` | broker | before the DLQ |
| `RETRY_BASE_MS` | `1000` | broker | first backoff step |
| `LB_STRATEGY` | `least-load` | broker | or `round-robin` |
| `CALL_TIMEOUT_MS` | `5000` | broker | upper bound for one `Handle` |
| `MAX_REROUTES` | `2` | broker | HA reroutes per call |

The broker also reads the Lab 3 `CIRCUIT_BREAKER_*` variables (Lab 3 §8).

## 11. Git

- `feature/lab4-<thing>` → PR to `development` → release PR to `main`.
- Conventional Commits. `VERSION` = `4.0.0`. CI publishes the image on merge to `main`.

## 12. Internal routes

Routes that only other services call (through `Broker.Call`). The gateway answers `404` for them to users. Each owner fills their service's table.

### game-service

| Service | Method | Path | Called by |
|---|---|---|---|
| game-service | – | none | – |

No other service calls Game: every Game route is a player route. Game reaches the others only by events (`game.session-ended`) and `Broker.Call`.

### exam-service

| Service | Method | Path | Called by |
|---|---|---|---|
| exam-service | – | none | – |

Other services do call Exam, but only on routes players use too, so the gateway must keep them open: `POST /exams` (game-service, Professor encounter), `GET /players/{playerId}/progress` (world-service and crafting-service, to check a passed course). The old `POST /events/exam-passed` to World and `POST /players/{id}/rewards` to Player are gone: both now come from the `exam.passed` event.

### world-service

| Service | Method | Path | Called by |
|---|---|---|---|
| world-service | POST | `/events/exam-passed` | nobody since Lab 4: Exam publishes `exam.passed`. Kept for manual tests, blocked at the gateway |

### zombie-service

None: every Zombie route is meant for users.

### resource-service

| Service | Method | Path | Called by |
|---|---|---|---|
| resource-service | POST | `/resources/consume` | base-service (upgrades, barricades, facilities, storage, decorations, feeding Kiki), crafting-service (materials) |
| resource-service | POST | `/resources/grant` | crafting-service, and any service that rewards resources |

Both are idempotent on `actionId`, and the callers send it as `Idempotency-Key` too, so the broker may reroute them. Resource stays open for the routes players use as well: `POST /resources/gather` (game-service calls it for a finished action, but players can gather through the gateway too), `GET /players/{playerId}/resources[/{resourceTypeId}]` (crafting-service reads a stock) and the resource-type routes.

### base-service

| Service | Method | Path | Called by |
|---|---|---|---|
| base-service | – | none | – |

No other service calls Base: every Base route is a player route. Base reaches the others with `Broker.Call` (Resource `consume`, Player, World) and the `base.upgraded` event, and listens to `player.leveled-up`.

### crafting-service

| Service | Method | Path | Called by |
|---|---|---|---|

### player-service

| Service | Method | Path | Called by |
|---|---|---|---|

## 13. Logs download

| Method | Path | Role | Answer |
|---|---|---|---|
| GET | `/admin/logs/download` (gateway) | `admin` | the matching lines from `$LOG_DIR/*.log` |

Query parameters, all optional: `service`, `instance`, `level`, `since`, `until`, `requestId`, `format=zip|ndjson`.

## 14. Monitoring

- **Prometheus** scrapes every instance found through SD `GET /prometheus/targets` (`http_sd`), plus the broker (`message-broker:8600/metrics`).
- **Grafana** has two dashboards: **Overview** (every service) and **Broker** (calls, events, queues, threads, DLQ).
- **Loki** collects the logs.

## 15. Who does what

| Grade | Work | Owner |
|---|---|---|
| – | This contract + `broker.proto` | Alexandru |
| 2, 5 | `message-broker` repo, CI, Docker, submodule | Alexandru |
| 6 | Broker router: subscriber-based + topic-based queues | Alexandru |
| 7 | Thread-per-Request in the broker, `GET /topics` | Alexandru |
| 8 | Game + Exam on gRPC and events | Alexandru |
| 3, 5 | Balancer + circuit breaker moved from the gateway into the broker | Vladlen |
| 9 | Durable queues (`SqliteStore`), DLQ + `/dlq` | Vladlen |
| 10 | HA reroute, least-load LB | Vladlen |
| 8 | Resource + Base on gRPC and events | Vladlen |
| – | README + architecture diagram | Vladlen |
| 5, 6 | Node broker client (`clients/node`), gateway via the broker | Mihai |
| 6 | Remove `8081` and the internal routes from the gateway, Lab 4 compose | Mihai |
| 8 | World + Zombie on gRPC and events | Mihai |
| 3, 6 | SD topics + `/prometheus/targets` | Gabriel |
| 4 | Logs download | Gabriel |
| 10 | Prometheus + Grafana + Loki | Gabriel |
| – | Lab 4 Postman collection | Gabriel |
| 8 | Player + Crafting on gRPC and events | Gabriel |
