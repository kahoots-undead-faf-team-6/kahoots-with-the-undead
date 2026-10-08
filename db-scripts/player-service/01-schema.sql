-- Player Service schema (PostgreSQL 16). Idempotent: safe to run on every start.

CREATE TABLE IF NOT EXISTS players (
  player_id     UUID PRIMARY KEY,
  username      TEXT NOT NULL,
  email         TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  display_name  TEXT NOT NULL,
  bio           TEXT NOT NULL DEFAULT '',
  avatar_url    TEXT,
  xp            INTEGER NOT NULL DEFAULT 0 CHECK (xp >= 0),
  presence      TEXT NOT NULL DEFAULT 'offline' CHECK (presence IN ('online', 'offline', 'in_game')),
  last_seen_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS players_username_key ON players (lower(username));
CREATE UNIQUE INDEX IF NOT EXISTS players_email_key ON players (lower(email));

-- Item catalog: consumables (Coffee, Energy Drinks, sandwiches), cosmetics, crafted equipment.
CREATE TABLE IF NOT EXISTS items (
  code        TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  category    TEXT NOT NULL CHECK (category IN ('consumable', 'cosmetic', 'equipment')),
  description TEXT NOT NULL DEFAULT ''
);

-- Rows are deleted when the quantity reaches 0. RESTRICT: an owned item can't leave the catalog.
CREATE TABLE IF NOT EXISTS inventory (
  player_id UUID    NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  item_code TEXT    NOT NULL REFERENCES items (code) ON DELETE RESTRICT,
  quantity  INTEGER NOT NULL CHECK (quantity >= 0),
  PRIMARY KEY (player_id, item_code)
);

-- Idempotency keys for item grants (e.g. Crafting Service uses its craftId).
CREATE TABLE IF NOT EXISTS inventory_grants (
  grant_id   TEXT PRIMARY KEY,
  player_id  UUID NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  items      JSONB NOT NULL,
  source     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One reward per (player, source, code), e.g. ("ACHIEVEMENT", "SURVIVED_THE_PUMPKIN").
CREATE TABLE IF NOT EXISTS rewards (
  player_id  UUID    NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  source     TEXT    NOT NULL,
  code       TEXT    NOT NULL,
  xp         INTEGER NOT NULL,
  items      JSONB   NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, source, code)
);

-- One row per pair of players; LEAST/GREATEST makes (a, b) and (b, a) the same pair.
CREATE TABLE IF NOT EXISTS friendships (
  requester_id UUID NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  addressee_id UUID NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  status       TEXT NOT NULL CHECK (status IN ('pending', 'accepted')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at  TIMESTAMPTZ,
  PRIMARY KEY (requester_id, addressee_id),
  CHECK (requester_id <> addressee_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS friendships_pair_key
  ON friendships (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id));

CREATE TABLE IF NOT EXISTS trades (
  trade_id       UUID PRIMARY KEY,
  from_player_id UUID  NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  to_player_id   UUID  NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
  offered        JSONB NOT NULL,
  requested      JSONB NOT NULL,
  message        TEXT,
  status         TEXT  NOT NULL CHECK (status IN ('pending', 'completed', 'rejected', 'cancelled')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at    TIMESTAMPTZ,
  CHECK (from_player_id <> to_player_id)
);
CREATE INDEX IF NOT EXISTS trades_from_idx ON trades (from_player_id);
CREATE INDEX IF NOT EXISTS trades_to_idx ON trades (to_player_id);
