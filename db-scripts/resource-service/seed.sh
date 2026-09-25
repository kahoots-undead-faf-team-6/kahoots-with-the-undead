#!/usr/bin/env bash
# Creates the resource-service tables and fills them ONLY if they are empty.
# Usage: DATABASE_URL=postgres://user:pass@localhost:5432/db ./seed.sh
#   or with Docker: docker exec -i <db-container> psql -U <user> -d <db> < schema.sql && ... < seed.sql
set -euo pipefail
cd "$(dirname "$0")"
: "${DATABASE_URL:?Set DATABASE_URL}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f seed.sql
echo "Done."
