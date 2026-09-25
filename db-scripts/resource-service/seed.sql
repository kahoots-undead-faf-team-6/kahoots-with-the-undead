-- Resource Service seed: runs ONLY if the tables are empty.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM resource_types) THEN
    INSERT INTO resource_types (id, name, description) VALUES
      ('wood',         'Wood',         'Basic building material'),
      ('metal_scraps', 'Metal scraps', 'Used for barricades and upgrades'),
      ('paper',        'Paper',        'Used for facilities and decorations'),
      ('food',         'Food',         'Keeps the player (and Kiki) alive');
    RAISE NOTICE 'Seeded resource_types';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM inventories) THEN
    INSERT INTO inventories (player_id, resource_type_id, quantity)
    SELECT p.player_id, q.resource_type_id, q.quantity
    FROM (VALUES ('player-1'), ('player-2'), ('player-3')) AS p(player_id)
    CROSS JOIN (VALUES ('wood', 50), ('metal_scraps', 20), ('paper', 30), ('food', 40)) AS q(resource_type_id, quantity);
    RAISE NOTICE 'Seeded inventories for 3 players';
  END IF;
END $$;
