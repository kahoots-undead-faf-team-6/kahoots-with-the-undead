-- Player Service seed. Each table is filled ONLY if it is empty, so this is safe to run many times.
-- 3 players with a starting inventory; password for all of them: "password123".
-- Player ids match the Game Service seed. Keep in sync with src/store/seed-data.ts.

INSERT INTO items (code, name, category, description)
SELECT v.code, v.name, v.category, v.description
FROM (VALUES
  ('COFFEE',            'Coffee',            'consumable', 'Keeps you awake through the night cycle'),
  ('ENERGY_DRINK',      'Energy Drink',      'consumable', 'Faster actions for a short time'),
  ('DAVIDAN_SANDWICH',  'Davidan Sandwich',  'consumable', 'Davidan branded, restores health'),
  ('FAF_HOODIE',        'FAF Hoodie',        'cosmetic',   'Show your faculty pride'),
  ('PUMPKIN_HAT',       'Pumpkin Hat',       'cosmetic',   'For those who survived the Pumpkin'),
  ('BARRICADE_KIT',     'Barricade Kit',     'equipment',  'Crafted: Wood + Metal'),
  ('IMPROVISED_WEAPON', 'Improvised Weapon', 'equipment',  'Crafted: Paper + Metal'),
  ('EXAM_CHEAT_SHEET',  'Exam Cheat Sheet',  'equipment',  'Crafted: Paper + Wood'),
  ('ENERGY_BOOSTER',    'Energy Booster',    'consumable', 'Crafted: Food + Chemicals'),
  ('ZOMBIE_DETECTOR',   'Zombie Detector',   'equipment',  'Crafted: Metal + Electronics')
) AS v(code, name, category, description)
WHERE NOT EXISTS (SELECT 1 FROM items);

INSERT INTO players (player_id, username, email, password_hash, display_name, bio, xp)
SELECT v.player_id::uuid, v.username, v.email, v.password_hash, v.display_name, v.bio, v.xp
FROM (VALUES
  ('aaaaaaaa-0000-4000-8000-000000000001', 'alice', 'alice@faf.utm.md',
   'scrypt$a1f00000000000000000000000000001$9bf2e0e1976aa33814869a08c1e5b687d5107b127109a530510ff7ed4971c94b',
   'Alice', 'Woke up in FAF Cab with an axe and a laptop.', 120),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'bob', 'bob@faf.utm.md',
   'scrypt$b0b00000000000000000000000000002$27a813ae35a23535f9257a62bc8e86141a26b0e7bacc0e7f6b918ece53839861',
   'Bob', 'Trades sandwiches for coffee.', 40),
  ('aaaaaaaa-0000-4000-8000-000000000003', 'carol', 'carol@faf.utm.md',
   'scrypt$ca1f0000000000000000000000000003$eb66caeef4488d64e9af14c353361a83ab1a527058fe9bead5d71bc6c98aba27',
   'Carol', 'First year, already behind on Linear Algebra.', 0)
) AS v(player_id, username, email, password_hash, display_name, bio, xp)
WHERE NOT EXISTS (SELECT 1 FROM players);

INSERT INTO inventory (player_id, item_code, quantity)
SELECT v.player_id::uuid, v.item_code, v.quantity
FROM (VALUES
  ('aaaaaaaa-0000-4000-8000-000000000001', 'COFFEE', 3),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'DAVIDAN_SANDWICH', 1),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'ENERGY_DRINK', 2),
  ('aaaaaaaa-0000-4000-8000-000000000001', 'FAF_HOODIE', 1),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'COFFEE', 1),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'DAVIDAN_SANDWICH', 3),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'ENERGY_DRINK', 1),
  ('aaaaaaaa-0000-4000-8000-000000000003', 'COFFEE', 2),
  ('aaaaaaaa-0000-4000-8000-000000000003', 'PUMPKIN_HAT', 1)
) AS v(player_id, item_code, quantity)
WHERE NOT EXISTS (SELECT 1 FROM inventory)
  AND EXISTS (SELECT 1 FROM players WHERE player_id = v.player_id::uuid);

INSERT INTO friendships (requester_id, addressee_id, status, accepted_at)
SELECT 'aaaaaaaa-0000-4000-8000-000000000001'::uuid, 'aaaaaaaa-0000-4000-8000-000000000002'::uuid, 'accepted', now()
WHERE NOT EXISTS (SELECT 1 FROM friendships)
  AND (SELECT count(*) FROM players WHERE player_id IN ('aaaaaaaa-0000-4000-8000-000000000001',
                                                        'aaaaaaaa-0000-4000-8000-000000000002')) = 2;
