-- Crafting Service schema (PostgreSQL 16). Idempotent: safe to run on every start.

CREATE TABLE IF NOT EXISTS recipes (
  recipe_id        UUID PRIMARY KEY,
  name             TEXT    NOT NULL,
  description      TEXT    NOT NULL DEFAULT '',
  ingredients      JSONB   NOT NULL,              -- [{ "resourceTypeId": "wood", "amount": 3 }]
  output_item_code TEXT    NOT NULL,              -- item code in the Player Service catalog
  output_quantity  INTEGER NOT NULL CHECK (output_quantity > 0),
  unlock           JSONB   NOT NULL DEFAULT '{}', -- { minLevel, requiredCourseId, requiredWingId, requiredResourceTypeId }
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS recipes_name_key ON recipes (lower(name));

-- Craft log. craft_id is the idempotency key, reused as the Resource actionId and the Player grantId.
-- No foreign key to recipes: the history keeps a copy of what was consumed and produced.
CREATE TABLE IF NOT EXISTS crafts (
  craft_id       UUID  PRIMARY KEY,
  player_id      UUID  NOT NULL,
  recipe_id      UUID  NOT NULL,
  recipe_name    TEXT  NOT NULL,
  consumed       JSONB NOT NULL,
  produced       JSONB NOT NULL,
  status         TEXT  NOT NULL CHECK (status IN ('pending', 'completed', 'failed')),
  failure_reason TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS crafts_player_idx ON crafts (player_id, created_at DESC);
