-- Resource Service schema (idempotent: safe to run on every start)
CREATE TABLE IF NOT EXISTS resource_types (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT
);

CREATE TABLE IF NOT EXISTS inventories (
  player_id        TEXT    NOT NULL,
  resource_type_id TEXT    NOT NULL REFERENCES resource_types(id) ON DELETE CASCADE,
  quantity         INTEGER NOT NULL CHECK (quantity >= 0),
  PRIMARY KEY (player_id, resource_type_id)
);

-- Every gather / consume / grant. action_id is the idempotency key.
CREATE TABLE IF NOT EXISTS resource_actions (
  action_id  TEXT PRIMARY KEY,
  kind       TEXT NOT NULL CHECK (kind IN ('gather', 'consume', 'grant')),
  player_id  TEXT NOT NULL,
  node_id    TEXT,
  source     TEXT,
  items      JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_resource_actions_player ON resource_actions (player_id);
CREATE INDEX IF NOT EXISTS idx_resource_actions_node   ON resource_actions (node_id);
