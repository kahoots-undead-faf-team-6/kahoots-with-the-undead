// Fills the Zombie Service DB only if it is empty. Usage: MONGO_URI=... MONGO_DB=zombie node seed.js
const { MongoClient } = require('mongodb');
const { randomUUID } = require('crypto');

const zombieTypes = () => [
  {
    name: 'Professor', description: 'Blocks corridors and asks deadly exam questions',
    stats: { speed: 1.0, health: 150, attack: 20, perceptionRadius: 8 },
    behavior: { mode: 'guard', aggressiveness: 0.8, fleeHealthPercent: 0, groupsUp: false },
    sprite: { url: 'sprites/professor.png', frameWidth: 32, frameHeight: 32 },
    abilities: [{ name: 'Pop Quiz', description: 'Stuns the player and starts an exam', cooldownSeconds: 20 }],
  },
  {
    name: 'Tourist', description: 'Wanders around taking photos, attacks when startled',
    stats: { speed: 1.5, health: 60, attack: 8, perceptionRadius: 5 },
    behavior: { mode: 'wander', aggressiveness: 0.3, fleeHealthPercent: 30, groupsUp: true },
    sprite: { url: 'sprites/tourist.png', frameWidth: 32, frameHeight: 32 },
    abilities: [{ name: 'Camera Flash', description: 'Briefly blinds the player', cooldownSeconds: 15 }],
  },
  {
    name: 'Overworked Student', description: 'Fast and reckless after an all-nighter',
    stats: { speed: 2.5, health: 40, attack: 12, perceptionRadius: 10 },
    behavior: { mode: 'chase', aggressiveness: 1, fleeHealthPercent: 0, groupsUp: true },
    sprite: { url: 'sprites/student.png', frameWidth: 32, frameHeight: 32 },
    abilities: [{ name: 'Caffeine Rush', description: 'Doubles speed for a few seconds', cooldownSeconds: 25 }],
  },
  {
    name: 'Dean', description: 'Slow boss that ambushes players in sealed wings',
    stats: { speed: 0.8, health: 400, attack: 35, perceptionRadius: 12 },
    behavior: { mode: 'ambush', aggressiveness: 0.9, fleeHealthPercent: 0, groupsUp: false },
    sprite: { url: 'sprites/dean.png', frameWidth: 48, frameHeight: 48 },
    abilities: [{ name: 'Expulsion Notice', description: 'Heavy damage to a single target', cooldownSeconds: 40 }],
  },
].map((t) => ({ ...t, _id: randomUUID() }));

async function seed(db) {
  const col = db.collection('zombie_types');
  if ((await col.estimatedDocumentCount()) > 0) {
    console.log('Collection "zombie_types" is not empty - skipping seed.');
    return false;
  }
  const docs = zombieTypes();
  await col.insertMany(docs);
  console.log(`Inserted ${docs.length} zombie types`);
  return true;
}

async function main() {
  const client = new MongoClient(process.env.MONGO_URI ?? 'mongodb://localhost:27017');
  await client.connect();
  try {
    await seed(client.db(process.env.MONGO_DB ?? 'zombie'));
  } finally {
    await client.close();
  }
}

module.exports = { seed, zombieTypes };
if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });
