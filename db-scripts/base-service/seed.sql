-- Base Service seed: runs ONLY if there are no bases. One FAF Cab per player.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bases) THEN
    INSERT INTO bases (player_id, name, level, storage_capacity) VALUES
      ('player-1', 'FAF Cab', 1, 100),
      ('player-2', 'FAF Cab', 1, 100),
      ('player-3', 'FAF Cab', 1, 100);
    RAISE NOTICE 'Seeded 3 FAF Cab bases';
  END IF;
END $$;
