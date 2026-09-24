# Database scripts

Each service has its own database (database per service). The scripts are plain SQL for PostgreSQL 16.

| Folder | DBMS | Contents |
|---|---|---|
| `game-service/` | PostgreSQL | `01-schema.sql` (sessions, actions, encounters), `02-seed.sql` (2 sessions, 3 actions) |
| `exam-service/` | PostgreSQL | `01-schema.sql` (courses, questions, exams, achievements), `02-seed.sql` (3 courses with 5 questions each) |

The seed scripts **insert data only when the tables are empty**, so they are safe to run many times.

The data gets loaded in three ways:
1. `deploy/docker-compose.yml` mounts these folders into `/docker-entrypoint-initdb.d`, so PostgreSQL runs them automatically the first time its volume is created.
2. Every service also runs the same scripts on startup when `SEED_ON_START=true`.
3. To load the data by hand into a running stack: `./db-scripts/seed.sh game-service` or `./db-scripts/seed.sh exam-service`.

Fixed ids in the seed data, useful for testing:
- Sessions `11111111-1111-4111-8111-111111111111` (active) and `22222222-2222-4222-8222-222222222222` (waiting)
- Players `aaaaaaaa-0000-4000-8000-000000000001` and `…0002`, which must match the Player Service seed
- Courses `f0000000-0000-4000-8000-000000000001` (Linear Algebra), `…0002` (PAD), `…0003` (FIA)
