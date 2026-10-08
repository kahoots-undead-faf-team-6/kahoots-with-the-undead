-- Crafting Service seed: 5 recipes, inserted ONLY if the table is empty (safe to run many times).
-- Keep in sync with src/store/seed-data.ts. Output item codes exist in the Player Service catalog.

INSERT INTO recipes (recipe_id, name, description, ingredients, output_item_code, output_quantity, unlock)
SELECT v.recipe_id::uuid, v.name, v.description, v.ingredients::jsonb, v.output_item_code, v.output_quantity, v.unlock::jsonb
FROM (VALUES
  ('e0000000-0000-4000-8000-000000000001', 'Barricade Kit',
   'Wood + Metal. Reinforces a room against the horde.',
   '[{"resourceTypeId":"wood","amount":3},{"resourceTypeId":"metal_scraps","amount":2}]',
   'BARRICADE_KIT', 1, '{}'),
  ('e0000000-0000-4000-8000-000000000002', 'Improvised Weapon',
   'Paper + Metal. Better than an axe, barely.',
   '[{"resourceTypeId":"paper","amount":2},{"resourceTypeId":"metal_scraps","amount":3}]',
   'IMPROVISED_WEAPON', 1, '{"minLevel":2}'),
  ('e0000000-0000-4000-8000-000000000003', 'Exam Cheat Sheet',
   'Paper + Wood. Only for those who already passed Linear Algebra.',
   '[{"resourceTypeId":"paper","amount":3},{"resourceTypeId":"wood","amount":1}]',
   'EXAM_CHEAT_SHEET', 1, '{"requiredCourseId":"f0000000-0000-4000-8000-000000000001"}'),
  ('e0000000-0000-4000-8000-000000000004', 'Energy Booster',
   'Food + Chemicals. Needs chemicals to have been discovered.',
   '[{"resourceTypeId":"food","amount":2},{"resourceTypeId":"chemicals","amount":1}]',
   'ENERGY_BOOSTER', 2, '{"requiredResourceTypeId":"chemicals"}'),
  ('e0000000-0000-4000-8000-000000000005', 'Zombie Detector',
   'Metal + Electronics. The parts are in the East Wing.',
   '[{"resourceTypeId":"metal_scraps","amount":2},{"resourceTypeId":"electronics","amount":2}]',
   'ZOMBIE_DETECTOR', 1, '{"minLevel":2,"requiredWingId":"d0000000-0000-4000-8000-000000000001"}')
) AS v(recipe_id, name, description, ingredients, output_item_code, output_quantity, unlock)
WHERE NOT EXISTS (SELECT 1 FROM recipes);
