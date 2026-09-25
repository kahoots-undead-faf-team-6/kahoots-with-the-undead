# Stand-in mocks: Player + Crafting

**These are NOT Gabriel's services.** They are contract stubs, added by Alexandru, so the team stack
runs end to end until Gabriel pushes his real images. They run on the public image `wiremock/wiremock:3.9.1`
(no `build:`). Every response has `"mock": true` and an `X-Mock` header.

| Service | Port | Endpoints | Used by |
|---|---|---|---|
| player-service | 3032 | `GET /health`, `GET /players`, `GET /players/{uuid}` (404 if not a UUID), `PATCH /players/{uuid}/xp {delta}`, `POST /players/{uuid}/rewards {source, code, xp}` | Game (validate player, XP), Exam (rewards) |
| crafting-service | 3031 | `GET /health`, `GET /recipes`, `POST /craft {playerId, recipeId}` | nobody yet |

No database and no state: XP changes are acknowledged, not stored.

To edit a response, change the JSON in `<service>/mappings/` and run `docker compose restart <service>`.

**Replacing them:** Gabriel swaps the `player-service` and `crafting-service` blocks in
`deploy/docker-compose.yml` for his images + PostgreSQL, keeps ports 3032/3031 (or updates
`PLAYER_SERVICE_URL`), and deletes this folder in the same PR.
