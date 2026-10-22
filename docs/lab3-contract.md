# Lab 3 – Scaling Up: shared contract

Every service follows these rules, whatever its language. If something here and a service README disagree, this file wins; change it here first, in a PR to `development`.

Version for every image this lab: **`3.0.0`** (and `latest`).

## 1. Service Discovery

**Service Discovery** (SD) is a new service written in the banned language (**Python 3.12, FastAPI**), repo `service-discovery`, submodule `services/service-discovery`, image `<user>/service-discovery:3.0.0`.

Inside the Docker network it listens on `http://service-discovery:8500`. The port is not published, except during the demo if we want to show the registry from the browser.

The registry lives in memory: if SD restarts, every service registers again on its next heartbeat (it gets a `404`, see below).

| Method | Path | Body | Answer |
|---|---|---|---|
| GET | `/health` | – | `200 {"status":"ok","service":"service-discovery"}` |
| GET | `/status` | – | the **status format** in §2 |
| POST | `/register` | `{"name","instanceId","host","port","metadata"?}` | `201` with the instance (`200` if that `instanceId` was already registered: it is updated) |
| PUT | `/instances/{instanceId}/heartbeat` | optional `{"load","inFlight"}` | `200` with the instance; **`404 INSTANCE_NOT_FOUND`** if SD doesn't know it, and the service must **register again** |
| DELETE | `/instances/{instanceId}?reason=<shutdown\|circuit-breaker>&reportedBy=<service>` | – | `204`; `404` if unknown |
| GET | `/instances/{instanceId}` | – | the instance |
| GET | `/services` | – | `{"services": {"game-service": [instance, ...], ...}}`: every instance, any status |
| GET | `/services/{name}` | – | `{"name": "...", "instances": [instance, ...]}`: only instances with `status: "UP"`. An unknown name gives an empty list, not 404 |

Instance object:

```json
{
  "instanceId": "game-1",
  "name": "game-service",
  "host": "172.18.0.7",
  "port": 3001,
  "url": "http://172.18.0.7:3001",
  "metadata": { "version": "3.0.0", "wsUrl": "ws://localhost:3101/ws" },
  "status": "UP",
  "registeredAt": "2026-10-22T10:00:00Z",
  "lastHeartbeatAt": "2026-10-22T10:00:05Z",
  "load": 0.1
}
```

Rules:
- **TTL.** An instance that sends no heartbeat for `HEARTBEAT_TTL_SECONDS` (default **15**, i.e. 3 missed heartbeats at 5 s) is removed. SD logs it at `WARN`.
- **Health checks (Grade 7).** Every `HEALTH_CHECK_INTERVAL_SECONDS` (default 10), SD calls `GET <url>/status` on every instance.
  - `load ≥ LOAD_WARN_THRESHOLD` (0.7) → `WARN` alert.
  - `load ≥ LOAD_CRITICAL_THRESHOLD` (0.9), status `DOWN`, or no answer → `CRITICAL` alert.
  - After `HEALTH_CHECK_FAILURES_BEFORE_DOWN` (2) failed checks in a row, the instance is marked `DOWN` and leaves `GET /services/{name}` until a check passes.
  - The same alert for the same instance is sent again only after `ALERT_COOLDOWN_SECONDS` (60).
- **Notifications (Grade 8).** Every alert also goes to Telegram and/or Discord (see §7). `POST /alerts/test` sends a test message.
- **Removal by circuit breaker (Grade 9).** `DELETE ...?reason=circuit-breaker` removes the instance and puts its `instanceId` in **quarantine** for `QUARANTINE_SECONDS` (60).
  - During quarantine, `POST /register` with that id answers **`409 INSTANCE_QUARANTINED`** and heartbeats answer `404`.
  - After quarantine, the instance's next heartbeat gets `404`, it registers again and it's back.
  - Every removal is logged and sent as a `CRITICAL` alert.

## 2. `/status` on every service (Grade 2)

`GET /status` bypasses the timeout and the concurrency limit (like `/health`), so SD can still read it when the service is overloaded.

The answer is `200` when the status is `UP` or `DEGRADED`, and `503` when it is `DOWN`:

```json
{
  "service": "game-service",
  "instanceId": "game-1",
  "version": "3.0.0",
  "status": "UP",
  "uptimeSeconds": 812,
  "inFlight": 3,
  "maxConcurrent": 50,
  "load": 0.06,
  "requestsTotal": 1204,
  "errorsTotal": 7,
  "dependencies": { "db": "UP", "service-discovery": "UP" },
  "circuitBreakers": { "exam-service": "CLOSED" },
  "timestamp": "2026-10-22T10:13:32Z"
}
```

- `load = inFlight / maxConcurrent`, rounded to 2 decimals. Grade 7 alerts on this field.
- `errorsTotal` counts responses with status ≥ 500.
- `status` is:
  - `DOWN` when a required dependency (its database) is down;
  - `DEGRADED` when an optional one is down or a breaker is `OPEN`;
  - otherwise `UP`.
- `dependencies` and `circuitBreakers` can be `{}` when the service has none.

## 3. Logs (Grade 2)

Every log line is **one JSON object** on stdout, so `docker compose logs -f` can be followed and grepped.

Required fields: `time` (ISO 8601), `level` (`DEBUG`/`INFO`/`WARN`/`ERROR`), `service`, `instanceId`, `msg`. Add `requestId` whenever there is a request.

`instanceId` is always the instance **writing** the line. Another instance (the one called, the one removed) goes in `upstreamInstance`, never in a second `instanceId` key.

| Event | Level | Extra fields |
|---|---|---|
| startup: version, port, storage, limits, SD URL (**never secrets**) | INFO | `port`, `version`, ... |
| registered / registration failed (retrying) / re-registered after 404 / deregistered | INFO / WARN | `sdUrl`, `attempt` |
| heartbeat failed | WARN | `status` or `err` |
| every incoming request (`/health` and `/status` only at DEBUG) | INFO, or WARN for ≥ 400, or ERROR for ≥ 500 | `method`, `path`, `status`, `durationMs`, `requestId` |
| every outgoing call to another service | INFO / WARN | `target`, `method`, `url`, `status`, `durationMs`, `upstreamInstance` |
| timeout, 429 limit hit | WARN | `path`, `limit` |
| circuit breaker: failure counted, tripped, half-open, closed, instance removed | WARN / ERROR | `target`, `failures`, `windowMs`, `upstreamInstance` |
| database errors | ERROR | `err` |
| shutdown | INFO | `signal` |

`LOG_LEVEL` (default `info`) controls the minimum level.

## 4. Headers

| Header | Who sets it | Meaning |
|---|---|---|
| `X-Request-Id` | the gateway (keeps the client's value or generates a UUID) | Every service logs it and **passes it on** on its outgoing calls, so one request can be followed across instances |
| `X-Instance-Id` (response) | every service, on every response; the gateway passes it to the caller | Which instance answered |
| `X-Served-By` (response) | the gateway | The service name |
| `X-Upstream-Error` (response) | the gateway, when the instance failed | `timeout` or `unreachable` (with `X-Instance-Id` = the instance it tried) |

## 5. Registration (Grade 4)

Every service instance, on startup:

1. Builds its instance:
   - `name` = `SERVICE_NAME` (`game-service`, `exam-service`, `world-service`, `zombie-service`, `resource-service`, `base-service`, `crafting-service`, `player-service`, `gateway`);
   - `instanceId` = `INSTANCE_ID`, default the container hostname;
   - `host` = `SERVICE_HOST`, default the container's own IPv4 address (not `localhost`, not the compose service name, because every replica shares that name);
   - `port` = its `PORT`;
   - `metadata.version`.
2. `POST /register`. If it fails, it retries every 2 s forever and logs each failure. The service already serves requests meanwhile.
3. Sends `PUT /instances/{id}/heartbeat` every `HEARTBEAT_INTERVAL_MS` (5000), with its current `load` and `inFlight`. On `404`, it registers again.
4. On `SIGTERM`/`SIGINT` it calls `DELETE /instances/{id}?reason=shutdown` (with a 2 s timeout), then stops.

`SERVICE_DISCOVERY_URL` empty means discovery is off: the Lab 2 static setup still works.

## 6. Round-robin at the gateway (Grade 5)

- The gateway asks SD for `GET /services/<prefix>-service` (`/game` → `game-service`, ...). It caches the answer for `DISCOVERY_CACHE_MS` (2000).
- It sends each request to the next instance in round-robin order, a separate counter per service.
- If SD can't be reached, it keeps the last list it got. If it never got one, it falls back to the static `ROUTE_<NAME>` URL. No instance at all → **503 `NO_INSTANCES`**.
- Every proxied response carries `X-Instance-Id` and `X-Served-By`.

**Instance-specific state.** A service must give the same answer whichever instance gets the request. State kept in memory (caches, counters, sessions, timers) is moved to the database, or documented as safe in the service's README under **"Running several instances"**.

**Game is the one exception the lab talks about:**
- Its live WebSocket connections are in memory. Game sends events between instances through PostgreSQL `LISTEN/NOTIFY`, so a player connected to any instance gets them.
- Each session has an **owner instance** in the DB. Only the owner runs that session's timers (day/night, action completion). If the owner dies, another instance takes the session over after 10 s.
- `POST /ws/negotiate` returns the WebSocket URL of the **owner** instance (`metadata.wsUrl`).

## 7. Circuit breaker (Grades 6 and 9)

**The task timeout limit** is the caller's own `REQUEST_TIMEOUT_MS` (5000 for the services, 10000 for the gateway). The **window** is `3.5 × REQUEST_TIMEOUT_MS`: 17.5 s for a service, 35 s for the gateway. `CIRCUIT_BREAKER_WINDOW_MS` overrides it, which helps in the demo.

- **What counts as a failure:** a timeout, a connection error, or a response with status ≥ 500 (including the gateway's `502`/`503`/`504`). A `4xx` is **not** a failure, because the request was wrong, not the service.
- **When it trips:** after `CIRCUIT_BREAKER_THRESHOLD` (**3**) failures for the same target inside the window. It applies to every endpoint of that target, and is kept per target service in the services and **per instance** at the gateway.
- **The log line when it trips** (level `ERROR`):

  ```json
  {"msg":"circuit breaker tripped","target":"exam-service","failures":3,"windowMs":17500,"instanceIds":["exam-2"],"mode":"remove"}
  ```

- **`CIRCUIT_BREAKER_MODE=log` (Grade 6):**
  - When it trips, the breaker logs and goes `OPEN`. While it is open, calls fail fast (`503 CIRCUIT_OPEN`, no request sent), for one window.
  - Then it goes `HALF_OPEN` and lets one call through: success closes it, failure opens it again.
  - Every state change is logged.
- **`CIRCUIT_BREAKER_MODE=remove` (Grade 9, the default):** when it trips, the caller removes the instances that failed.
  - It calls `DELETE /instances/{id}?reason=circuit-breaker&reportedBy=<self>` on SD for every `instanceId` that failed in the window. Services learn the id from the gateway's `X-Instance-Id` header.
  - The gateway also drops the instance from its round-robin pool right away.
  - Then the failure counter resets and the breaker stays `CLOSED`, because the healthy instances keep serving.
  - If no instance id is known (the gateway itself is down), it behaves like `log` mode.

## 8. Environment variables (every service)

| Variable | Default | Meaning |
|---|---|---|
| `SERVICE_NAME` | the service name | Name in SD |
| `INSTANCE_ID` | container hostname | Unique per replica |
| `SERVICE_HOST` | container IPv4 | Address SD and the gateway use |
| `SERVICE_DISCOVERY_URL` | empty (off) | `http://service-discovery:8500` in compose |
| `HEARTBEAT_INTERVAL_MS` | `5000` | |
| `LOG_LEVEL` | `info` | |
| `CIRCUIT_BREAKER_MODE` | `remove` | `log` or `remove` |
| `CIRCUIT_BREAKER_THRESHOLD` | `3` | |
| `CIRCUIT_BREAKER_WINDOW_MS` | `3.5 × REQUEST_TIMEOUT_MS` | |

SD only: `HEARTBEAT_TTL_SECONDS`, `HEALTH_CHECK_INTERVAL_SECONDS`, `HEALTH_CHECK_FAILURES_BEFORE_DOWN`, `LOAD_WARN_THRESHOLD`, `LOAD_CRITICAL_THRESHOLD`, `ALERT_COOLDOWN_SECONDS`, `QUARANTINE_SECONDS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DISCORD_WEBHOOK_URL`.

## 9. Who does what

| Grade | Work | Owner |
|---|---|---|
| 1 | `service-discovery` repo, README, CI, submodule, this contract | Alexandru |
| 2 | `/status` + JSON logs: Game, Exam, Gateway | Alexandru |
| 2 | `/status` + JSON logs: World, Zombie / Resource, Base / Crafting, Player / SD | Mihai / Vladlen / Gabriel / Mihai |
| 3 | SD registry (register, heartbeat, TTL, lookup), Dockerfile, DockerHub | Mihai |
| 4 | Registration in Game, Exam, Gateway | Alexandru |
| 4 | Registration in each teammate's two services | each owner |
| 4 | Compose: SD, 2–3 replicas per service, no fixed ports | Mihai |
| 5 | Gateway round-robin through SD, Game session ownership and event relay | Alexandru |
| 5 | Instance-agnostic check of each service | each owner |
| 6 | Circuit breaker in Game and Exam | Alexandru |
| 6 | Circuit breaker in the gateway (per instance) | Vladlen |
| 6 | Circuit breaker in World, Resource, Base, Crafting | each owner |
| 7 | SD health polling and load alerts | Gabriel |
| 8 | Telegram/Discord notifications | Gabriel |
| 9 | Removal mode: gateway + SD quarantine | Vladlen |
| 9 | Removal mode in each owner's own services | each owner |
| – | Lab 3 Postman collection | Gabriel |
| – | Architecture diagram update | Vladlen |
