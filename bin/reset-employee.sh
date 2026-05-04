#!/bin/bash
# reset-employee.sh <login>
# Nukes a single employee's home + cache volumes and rebuilds the
# container. The fresh container will generate a new id_ed25519 keypair —
# you'll need to re-authorise it on any upstream host (Mac mini build
# dispatcher, droplet, etc.) but the manager's MANAGER_SSH_PUBKEY in the
# env file is still valid (the manager's fanout key didn't change).
#
# Use 'manager' as <login> to reset the manager-agent container.
set -euo pipefail

DEV_ENV_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DEV_ENV_DIR"

LOGIN="${1:-}"
if [ -z "$LOGIN" ]; then
    echo "usage: reset-employee.sh <login>     # 'manager' for the manager-agent" >&2
    exit 2
fi

if [ "$LOGIN" = "manager" ]; then
    SERVICE="manager-agent"
    CONTAINER="onym-manager-agent"
    HOME_VOL="onym-n8n_manager-home"
    CACHE_VOL="onym-n8n_manager-cache"
else
    if ! jq -e --arg l "$LOGIN" '.employees | has($l)' employees.json >/dev/null 2>&1; then
        echo "ERROR: '$LOGIN' is not in employees.json" >&2
        exit 3
    fi
    SERVICE="${LOGIN}-agent"
    CONTAINER="onym-${LOGIN}-agent"
    HOME_VOL="onym-n8n_${LOGIN}-home"
    CACHE_VOL="onym-n8n_${LOGIN}-cache"
fi

./bin/render-employees-compose.sh >/dev/null

OVERLAY=""
[ -f docker-compose.employees.yml ] && OVERLAY="-f docker-compose.employees.yml"

echo "==> stopping ${SERVICE}"
docker compose -f docker-compose.dev.yml ${OVERLAY} stop "$SERVICE" || true
docker compose -f docker-compose.dev.yml ${OVERLAY} rm -f "$SERVICE" || true

echo "==> removing volumes ($HOME_VOL, $CACHE_VOL)"
docker volume rm "$HOME_VOL" "$CACHE_VOL" 2>&1 || true

echo "==> rebuilding ${SERVICE}"
docker compose -f docker-compose.dev.yml ${OVERLAY} up -d --build "$SERVICE"

echo
echo "==> new public key (authorise upstream as needed):"
sleep 2
docker logs "$CONTAINER" 2>&1 | awk '/^ssh-ed25519/{print}' | tail -1 || true

if [ "$LOGIN" = "manager" ]; then
    echo
    echo "==> new MANAGER_SSH_PUBKEY (paste into every employees/<login>.env):"
    docker logs "$CONTAINER" 2>&1 \
      | awk '/MANAGER_SSH_PUBKEY \(paste/{flag=1; next} /end MANAGER_SSH_PUBKEY/{flag=0} flag' \
      | tail -1 || true
fi
