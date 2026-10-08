#!/usr/bin/env bash
# Creates deploy/.env from deploy/.env.example with a random value for every
# "change-me..." password and secret, so the stack starts with one command:
#   ./deploy/setup-env.sh && docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d
# An existing deploy/.env is kept (pass --force to regenerate it; the databases
# keep their old passwords in their volumes, so also run "docker compose down -v").
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ] && [ "${1:-}" != "--force" ]; then
  echo "[setup-env] deploy/.env already exists, keeping it (use --force to regenerate)"
  exit 0
fi

random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; }

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^([A-Z0-9_]+)=change-me ]]; then
    echo "${BASH_REMATCH[1]}=$(random 40)"
  else
    echo "$line"
  fi
done < .env.example > .env

echo "[setup-env] wrote deploy/.env with random passwords and secrets"
echo "[setup-env] admin token key: $(grep '^ADMIN_KEY=' .env | cut -d= -f2)"
