-- Base Service schema (idempotent: safe to run on every start)
CREATE TABLE IF NOT EXISTS bases (
  player_id        TEXT PRIMARY KEY,
  name             TEXT        NOT NULL,
  level            INTEGER     NOT NULL DEFAULT 1 CHECK (level >= 1),
  storage_capacity INTEGER     NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS barricades (
  id         TEXT PRIMARY KEY,
  player_id  TEXT        NOT NULL REFERENCES bases(player_id) ON DELETE CASCADE,
  room_id    TEXT        NOT NULL,
  strength   INTEGER     NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (player_id, room_id)
);

CREATE TABLE IF NOT EXISTS facilities (
  id         TEXT PRIMARY KEY,
  player_id  TEXT        NOT NULL REFERENCES bases(player_id) ON DELETE CASCADE,
  type       TEXT        NOT NULL,
  level      INTEGER     NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (player_id, type)
);

CREATE TABLE IF NOT EXISTS decorations (
  id         TEXT PRIMARY KEY,
  player_id  TEXT        NOT NULL REFERENCES bases(player_id) ON DELETE CASCADE,
  name       TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS kiki_interactions (
  action_id  TEXT PRIMARY KEY,
  player_id  TEXT        NOT NULL REFERENCES bases(player_id) ON DELETE CASCADE,
  reward     JSONB,
  message    TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency log for paid/rewarded operations (upgrade, barricade, facility, kiki)
CREATE TABLE IF NOT EXISTS base_actions (
  action_id  TEXT PRIMARY KEY,
  player_id  TEXT        NOT NULL,
  kind       TEXT        NOT NULL,
  result     JSONB       NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
