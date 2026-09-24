// Fills the World Service DB only if it is empty. Usage: MONGO_URI=... MONGO_DB=world node seed.js
const { MongoClient } = require('mongodb');
const { randomUUID } = require('crypto');

const COLLECTIONS = ['wings', 'rooms', 'corridors', 'zones', 'resource_nodes', 'barricades', 'spawn_configs'];

function buildData() {
  const id = () => randomUUID();
  const wingEast = { _id: id(), name: 'East Wing', unlocked: false, requiredCourseId: 'course-algorithms' };
  const zoneSafe = { _id: id(), name: 'Safe Zone', description: 'Around FAF Cab', dangerLevel: 1 };
  const zoneMain = { _id: id(), name: 'Main Building', description: 'Public rooms', dangerLevel: 4 };
  const zoneEast = { _id: id(), name: 'East Wing Zone', description: 'Sealed until an exam is passed', dangerLevel: 8 };

  const room = (name, type, zone, wing = null, description = '') => ({ _id: id(), name, type, wingId: wing?._id ?? null, zoneId: zone._id, description });
  const cab = room('FAF Cab', 'base', zoneSafe, null, 'Starting room and base');
  const canteen = room('Canteen', 'canteen', zoneMain, null, 'Food');
  const library = room('Library', 'library', zoneMain, null, 'Paper');
  const lab = room('Laboratory', 'laboratory', zoneMain, null, 'Metal scraps');
  const class1 = room('Classroom 101', 'classroom', zoneMain, null, 'Textbooks');
  const class2 = room('Classroom 102', 'classroom', zoneMain, null, 'Textbooks');
  const server = room('Server Room', 'other', zoneEast, wingEast, 'Locked until East Wing opens');
  const rooms = [cab, canteen, library, lab, class1, class2, server];

  const corridor = (a, b, locked = false) => ({ _id: id(), fromRoomId: a._id, toRoomId: b._id, locked });
  const corridors = [corridor(cab, canteen), corridor(cab, library), corridor(canteen, lab), corridor(library, class1), corridor(class1, class2), corridor(lab, server, true)];

  const node = (r, resourceType, quantity, respawnSeconds) => ({ _id: id(), roomId: r._id, resourceType, quantity, respawnSeconds });
  const resourceNodes = [
    node(lab, 'metal_scraps', 25, 180),
    node(library, 'paper', 40, 120),
    node(canteen, 'food', 30, 150),
    node(class1, 'textbooks', 10, 240),
    node(class2, 'textbooks', 10, 240),
  ];

  const barricades = [{ _id: id(), roomId: cab._id, health: 100, maxHealth: 100 }];
  const spawn = (r, zombieType, maxZombies, intervalSeconds) => ({ _id: id(), roomId: r._id, zombieType, maxZombies, intervalSeconds, active: true });
  const spawnConfigs = [spawn(canteen, 'TOURIST', 3, 60), spawn(lab, 'PROFESSOR', 1, 120), spawn(class1, 'OVERWORKED_STUDENT', 4, 45), spawn(server, 'DEAN', 1, 300)];

  return {
    wings: [wingEast],
    zones: [zoneSafe, zoneMain, zoneEast],
    rooms,
    corridors,
    resource_nodes: resourceNodes,
    barricades,
    spawn_configs: spawnConfigs,
  };
}

async function seed(db) {
  for (const name of COLLECTIONS) {
    if ((await db.collection(name).estimatedDocumentCount()) > 0) {
      console.log(`Collection "${name}" is not empty - skipping seed.`);
      return false;
    }
  }
  const data = buildData();
  for (const [name, docs] of Object.entries(data)) {
    await db.collection(name).insertMany(docs);
    console.log(`Inserted ${docs.length} into ${name}`);
  }
  return true;
}

async function main() {
  const client = new MongoClient(process.env.MONGO_URI ?? 'mongodb://localhost:27017');
  await client.connect();
  try {
    await seed(client.db(process.env.MONGO_DB ?? 'world'));
  } finally {
    await client.close();
  }
}

module.exports = { seed, buildData };
if (require.main === module) main().catch((e) => { console.error(e); process.exit(1); });
