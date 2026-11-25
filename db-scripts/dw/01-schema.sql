-- Lab 5: Data Warehouse (star schema, schema "dw"). Loaded by etl-service from every service's database.
-- Idempotent: safe on every start. Every fact/dimension row is keyed by source_id (the key in the source
-- database), so the ETL upserts (INSERT ... ON CONFLICT (source_id) DO UPDATE) and a repeated run never
-- duplicates rows. source_updated_at is the source row's updated_at/created_at; loaded_at is when the ETL
-- last wrote it.

CREATE SCHEMA IF NOT EXISTS dw;

-- ---------------------------------------------------------------- dimensions

-- One row per day, generated here (2025-01-01 .. 2030-12-31). Facts point to it with date_key = YYYYMMDD.
CREATE TABLE IF NOT EXISTS dw.dim_date (
  date_key    INTEGER PRIMARY KEY,           -- 20261126
  date        DATE    NOT NULL UNIQUE,
  year        SMALLINT NOT NULL,
  quarter     SMALLINT NOT NULL,
  month       SMALLINT NOT NULL,
  month_name  TEXT    NOT NULL,
  day         SMALLINT NOT NULL,
  iso_week    SMALLINT NOT NULL,
  weekday     SMALLINT NOT NULL,             -- 1 = Monday .. 7 = Sunday
  weekday_name TEXT   NOT NULL,
  is_weekend  BOOLEAN NOT NULL
);
INSERT INTO dw.dim_date
SELECT to_char(d, 'YYYYMMDD')::int, d::date, extract(year FROM d), extract(quarter FROM d), extract(month FROM d),
       trim(to_char(d, 'Month')), extract(day FROM d), extract(week FROM d), extract(isodow FROM d),
       trim(to_char(d, 'Day')), extract(isodow FROM d) IN (6, 7)
FROM generate_series('2025-01-01'::date, '2030-12-31'::date, interval '1 day') AS d
ON CONFLICT (date_key) DO NOTHING;

-- player-db.players
CREATE TABLE IF NOT EXISTS dw.dim_player (
  source_id         TEXT PRIMARY KEY,        -- player_id
  username          TEXT NOT NULL,
  display_name      TEXT,
  level             INTEGER NOT NULL,        -- computed from xp with Player Service's curve (50 * L * (L - 1))
  xp                INTEGER NOT NULL,
  created_at        TIMESTAMPTZ,
  created_date_key  INTEGER REFERENCES dw.dim_date (date_key),
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- world-mongo: rooms, with their zone and wing (and whether the wing is unlocked)
CREATE TABLE IF NOT EXISTS dw.dim_room (
  source_id         TEXT PRIMARY KEY,        -- room id
  name              TEXT NOT NULL,
  room_type         TEXT,
  zone_id           TEXT,
  zone_name         TEXT,
  wing_id           TEXT,
  wing_name         TEXT,
  wing_unlocked     BOOLEAN,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- zombie-mongo.zombie_types
CREATE TABLE IF NOT EXISTS dw.dim_zombie_type (
  source_id         TEXT PRIMARY KEY,        -- zombie type id
  code              TEXT NOT NULL,
  name              TEXT NOT NULL,
  speed             NUMERIC,
  health            INTEGER,
  attack            NUMERIC,
  behavior_mode     TEXT,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- resource-db.resource_types
CREATE TABLE IF NOT EXISTS dw.dim_resource_type (
  source_id         TEXT PRIMARY KEY,        -- resource type id ("wood")
  name              TEXT NOT NULL,
  description       TEXT,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- crafting-db.recipes
CREATE TABLE IF NOT EXISTS dw.dim_recipe (
  source_id         TEXT PRIMARY KEY,        -- recipe_id
  name              TEXT NOT NULL,
  output_item_code  TEXT,
  output_quantity   INTEGER,
  min_level         INTEGER,
  required_course_id TEXT,
  ingredients       JSONB,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- facts

-- game-db: one row per (session, player): what the player did in the session
CREATE TABLE IF NOT EXISTS dw.fact_game_session (
  source_id         TEXT PRIMARY KEY,        -- "<session_id>:<player_id>"
  session_id        TEXT NOT NULL,
  player_id         TEXT NOT NULL,
  session_status    TEXT NOT NULL,           -- waiting | active | finished
  date_key          INTEGER REFERENCES dw.dim_date (date_key),
  created_at        TIMESTAMPTZ,
  started_at        TIMESTAMPTZ,
  actions_total     INTEGER NOT NULL DEFAULT 0,
  actions_completed INTEGER NOT NULL DEFAULT 0,
  action_seconds    INTEGER NOT NULL DEFAULT 0, -- time spent in completed actions
  encounters        INTEGER NOT NULL DEFAULT 0,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- exam-db.exams (+ course name)
CREATE TABLE IF NOT EXISTS dw.fact_exam_attempt (
  source_id         TEXT PRIMARY KEY,        -- exam_id
  player_id         TEXT NOT NULL,
  course_id         TEXT NOT NULL,
  course_name       TEXT,
  course_category   TEXT,
  status            TEXT NOT NULL,           -- in_progress | passed | failed | abandoned
  passed            BOOLEAN NOT NULL,
  score             INTEGER,
  grade             INTEGER,
  attempt_number    INTEGER,
  date_key          INTEGER REFERENCES dw.dim_date (date_key),
  created_at        TIMESTAMPTZ,
  finished_at       TIMESTAMPTZ,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- resource-db.resource_actions: one row per (action, resource type) of its items
CREATE TABLE IF NOT EXISTS dw.fact_resource_op (
  source_id         TEXT PRIMARY KEY,        -- "<action_id>:<resource_type_id>"
  action_id         TEXT NOT NULL,
  op                TEXT NOT NULL,           -- gather | consume | grant | revert
  player_id         TEXT NOT NULL,
  resource_type_id  TEXT NOT NULL,
  quantity          INTEGER NOT NULL,
  node_id           TEXT,
  date_key          INTEGER REFERENCES dw.dim_date (date_key),
  created_at        TIMESTAMPTZ,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- crafting-db.crafts
CREATE TABLE IF NOT EXISTS dw.fact_craft (
  source_id         TEXT PRIMARY KEY,        -- craft_id
  player_id         TEXT NOT NULL,
  recipe_id         TEXT NOT NULL,
  recipe_name       TEXT,
  status            TEXT NOT NULL,           -- common values: PENDING | COMPLETED | FAILED
  failure_reason    TEXT,
  saga_id           TEXT,                    -- Lab 5 saga, when the craft ran as one
  item_code         TEXT,
  item_quantity     INTEGER,
  date_key          INTEGER REFERENCES dw.dim_date (date_key),
  created_at        TIMESTAMPTZ,
  completed_at      TIMESTAMPTZ,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- base-db.base_actions of an upgrade kind (+ the base's player)
CREATE TABLE IF NOT EXISTS dw.fact_base_upgrade (
  source_id         TEXT PRIMARY KEY,        -- action_id / upgradeId
  base_id           TEXT NOT NULL,
  player_id         TEXT,
  upgrade_kind      TEXT NOT NULL,           -- BASE_UPGRADE | FACILITY_UPGRADE | ...
  status            TEXT NOT NULL,           -- common values: PENDING | COMPLETED | FAILED
  saga_id           TEXT,
  date_key          INTEGER REFERENCES dw.dim_date (date_key),
  created_at        TIMESTAMPTZ,
  source_updated_at TIMESTAMPTZ,
  loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fact_game_session_date_idx ON dw.fact_game_session (date_key);
CREATE INDEX IF NOT EXISTS fact_exam_attempt_course_idx ON dw.fact_exam_attempt (course_id);
CREATE INDEX IF NOT EXISTS fact_resource_op_type_idx ON dw.fact_resource_op (resource_type_id, op);
CREATE INDEX IF NOT EXISTS fact_craft_date_idx ON dw.fact_craft (date_key);
CREATE INDEX IF NOT EXISTS fact_base_upgrade_date_idx ON dw.fact_base_upgrade (date_key);

-- ---------------------------------------------------------------- ETL bookkeeping

CREATE TABLE IF NOT EXISTS dw.etl_runs (
  run_id       BIGSERIAL PRIMARY KEY,
  trigger      TEXT NOT NULL,                -- startup | schedule | manual
  status       TEXT NOT NULL,                -- RUNNING | SUCCESS | PARTIAL | FAILED
  started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at  TIMESTAMPTZ,
  duration_ms  INTEGER,
  rows_loaded  JSONB NOT NULL DEFAULT '{}',  -- { "player-service": 3, ... }
  errors       JSONB NOT NULL DEFAULT '{}'   -- { "world-service": "connect ECONNREFUSED ..." }
);

-- The last source_updated_at read from each source, moved only after that source's load committed.
CREATE TABLE IF NOT EXISTS dw.etl_watermarks (
  source      TEXT PRIMARY KEY,
  watermark   TIMESTAMPTZ NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
