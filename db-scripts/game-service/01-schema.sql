-- Game Service schema. Safe to run many times.
CREATE TABLE IF NOT EXISTS sessions (
    session_id  UUID PRIMARY KEY,
    name        TEXT        NOT NULL,
    status      TEXT        NOT NULL CHECK (status IN ('waiting', 'active', 'finished')),
    max_players INT         NOT NULL CHECK (max_players BETWEEN 1 AND 8),
    players     TEXT[]      NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL,
    started_at  TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS actions (
    action_id    UUID PRIMARY KEY,
    session_id   UUID        NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    player_id    UUID        NOT NULL,
    type         TEXT        NOT NULL,
    target_id    UUID        NOT NULL,
    status       TEXT        NOT NULL CHECK (status IN ('in_progress', 'completed', 'cancelled')),
    started_at   TIMESTAMPTZ NOT NULL,
    ends_at      TIMESTAMPTZ NOT NULL,
    duration_sec INT         NOT NULL
);
CREATE INDEX IF NOT EXISTS actions_status_idx  ON actions (status);
CREATE INDEX IF NOT EXISTS actions_session_idx ON actions (session_id);

CREATE TABLE IF NOT EXISTS encounters (
    encounter_id UUID PRIMARY KEY,
    session_id   UUID        NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    player_id    UUID        NOT NULL,
    zombie_id    UUID        NOT NULL,
    zombie_type  TEXT        NOT NULL,
    outcome      TEXT        NOT NULL,
    exam_id      UUID,
    created_at   TIMESTAMPTZ NOT NULL
);
