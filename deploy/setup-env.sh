#!/usr/bin/env bash
# Creates deploy/.env from deploy/.env.example with a random value for every
# "change-me..." password and secret, so the stack starts with one command:
#   ./deploy/setup-env.sh && docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d
#
#   --demo   also sets DEMO_MODE=true and low limits, so the 408 / 429 / 504 demos and
#            every folder of postman/lab2-gateway.postman_collection.json pass
#   --force  regenerate an existing deploy/.env (the databases keep their old passwords
#            in their volumes, so also run "docker compose down -v")
#
# It also writes deploy/lab2.postman_environment.json (gitignored) with gatewayUrl and
# the generated adminKey: import it in Postman next to the collection.
set -euo pipefail
cd "$(dirname "$0")"

demo=false force=false
for arg in "$@"; do
  case "$arg" in
    --demo) demo=true ;;
    --force) force=true ;;
    *) echo "usage: $0 [--demo] [--force]" >&2; exit 2 ;;
  esac
done

if [ -f .env ] && [ "$force" = false ]; then
  echo "[setup-env] deploy/.env already exists, keeping it (use --force to regenerate)"
else
  random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; }

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Z0-9_]+)=change-me ]]; then
      echo "${BASH_REMATCH[1]}=$(random 40)"
    elif [ "$demo" = true ] && [[ "$line" =~ ^(DEMO_MODE|GATEWAY_MAX_CONCURRENT_REQUESTS|SERVICE_REQUEST_TIMEOUT_MS)= ]]; then
      case "${BASH_REMATCH[1]}" in
        DEMO_MODE) echo "DEMO_MODE=true" ;;
        GATEWAY_MAX_CONCURRENT_REQUESTS) echo "GATEWAY_MAX_CONCURRENT_REQUESTS=5" ;;
        SERVICE_REQUEST_TIMEOUT_MS) echo "SERVICE_REQUEST_TIMEOUT_MS=3000" ;;
      esac
    else
      echo "$line"
    fi
  done < .env.example > .env

  echo "[setup-env] wrote deploy/.env with random passwords and secrets$([ "$demo" = true ] && echo ' (demo limits)')"
fi

admin_key=$(grep '^ADMIN_KEY=' .env | cut -d= -f2)
cat > lab2.postman_environment.json <<EOF
{
  "name": "Lab 2 (local stack)",
  "values": [
    { "key": "gatewayUrl", "value": "http://localhost:8080", "enabled": true },
    { "key": "adminKey", "value": "$admin_key", "enabled": true }
  ]
}
EOF
echo "[setup-env] wrote deploy/lab2.postman_environment.json (import it in Postman)"
echo "[setup-env] admin key: $admin_key"
