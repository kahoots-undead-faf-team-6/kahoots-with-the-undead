#!/usr/bin/env bash
# Populate a service database with sample data if it is empty.
# The seed scripts check for existing rows first, so running this many times never duplicates data.
#
#   ./db-scripts/seed.sh game-service
#   ./db-scripts/seed.sh exam-service
#
# Needs the team stack to be running: docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d
set -euo pipefail
cd "$(dirname "$0")/.."

service="${1:?usage: ./db-scripts/seed.sh <game-service|exam-service>}"
case "$service" in
  game-service) db_container=game-db; prefix=GAME ;;
  exam-service) db_container=exam-db; prefix=EXAM ;;
  *) echo "unknown service: $service"; exit 1 ;;
esac

set -a; source deploy/.env; set +a
user_var="${prefix}_DB_USER"; name_var="${prefix}_DB_NAME"

for f in db-scripts/"$service"/*.sql; do
  echo "Running $f"
  docker compose -f deploy/docker-compose.yml --env-file deploy/.env exec -T "$db_container" \
    psql -v ON_ERROR_STOP=1 -U "${!user_var}" -d "${!name_var}" < "$f"
done
echo "Done: $service database is seeded."
