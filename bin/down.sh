#!/bin/bash
# Stop the dev-env stack. Does NOT remove volumes — agent state
# (workspace, Claude login, generated SSH keys) survives. Use
# reset-employee.sh to wipe a single employee's volumes.
set -euo pipefail

DEV_ENV_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DEV_ENV_DIR"

# Render fresh overlay so down sees the same service names as up did.
if [ -f employees.json ]; then
    ./bin/render-employees-compose.sh >/dev/null
fi

OVERLAY="docker-compose.employees.yml"
if [ -f "$OVERLAY" ]; then
    docker compose -f docker-compose.dev.yml -f "$OVERLAY" down
else
    docker compose -f docker-compose.dev.yml down
fi
