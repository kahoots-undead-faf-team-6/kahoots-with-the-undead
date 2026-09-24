-- Game Service seed data. Inserts only when the sessions table is empty.
-- Player ids match the Player Service seed (3 players); room/node ids match the World Service mock.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sessions) THEN
        INSERT INTO sessions (session_id, name, status, max_players, players, created_at, started_at) VALUES
            ('11111111-1111-4111-8111-111111111111', 'FAF Cab Survivors', 'active', 4,
             ARRAY['aaaaaaaa-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000002'],
             now() - interval '20 minutes', now() - interval '15 minutes'),
            ('22222222-2222-4222-8222-222222222222', 'Night Shift in the Library', 'waiting', 3,
             ARRAY[]::TEXT[], now() - interval '5 minutes', NULL);

        INSERT INTO actions (action_id, session_id, player_id, type, target_id, status, started_at, ends_at, duration_sec) VALUES
            ('33333333-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
             'aaaaaaaa-0000-4000-8000-000000000001', 'SCAVENGE_CANTEEN', 'cccccccc-0000-4000-8000-000000000002',
             'completed', now() - interval '14 minutes', now() - interval '9 minutes', 300),
            ('33333333-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
             'aaaaaaaa-0000-4000-8000-000000000002', 'CLEAR_ROOM', 'bbbbbbbb-0000-4000-8000-000000000003',
             'cancelled', now() - interval '12 minutes', now() - interval '9 minutes', 180),
            ('33333333-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111',
             'aaaaaaaa-0000-4000-8000-000000000002', 'CHOP_BENCHES', 'cccccccc-0000-4000-8000-000000000001',
             'in_progress', now(), now() + interval '10 minutes', 600);
    END IF;
END $$;
