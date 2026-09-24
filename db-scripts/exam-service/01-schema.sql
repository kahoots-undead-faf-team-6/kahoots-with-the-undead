-- Exam Service schema. Safe to run many times.
CREATE TABLE IF NOT EXISTS courses (
    course_id  UUID PRIMARY KEY,
    name       TEXT        NOT NULL,
    category   TEXT        NOT NULL CHECK (category IN ('MATH', 'PROGRAMMING', 'NETWORKS', 'HUMANITIES')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS questions (
    question_id    UUID PRIMARY KEY,
    course_id      UUID   NOT NULL REFERENCES courses (course_id) ON DELETE CASCADE,
    text           TEXT   NOT NULL,
    options        TEXT[] NOT NULL,
    correct_option INT    NOT NULL,
    position       BIGSERIAL
);
CREATE INDEX IF NOT EXISTS questions_course_idx ON questions (course_id);

CREATE TABLE IF NOT EXISTS exams (
    exam_id        UUID PRIMARY KEY,
    player_id      UUID        NOT NULL,
    course_id      UUID        NOT NULL REFERENCES courses (course_id),
    session_id     UUID,
    zombie_id      UUID,
    status         TEXT        NOT NULL CHECK (status IN ('in_progress', 'passed', 'failed', 'abandoned')),
    attempt_number INT         NOT NULL,
    question_ids   TEXT[]      NOT NULL,
    score          INT         NOT NULL DEFAULT 0,
    grade          INT         NOT NULL DEFAULT 0,
    created_at     TIMESTAMPTZ NOT NULL,
    expires_at     TIMESTAMPTZ NOT NULL,
    finished_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS exams_player_idx ON exams (player_id);

CREATE TABLE IF NOT EXISTS achievements (
    player_id   UUID        NOT NULL,
    code        TEXT        NOT NULL,
    name        TEXT        NOT NULL,
    unlocked_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (player_id, code)
);
