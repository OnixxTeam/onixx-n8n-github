#!/bin/bash
# Wrapper invoked by ~/Library/LaunchAgents/com.onym.n8n.plist on
# auto-login. Waits for Docker to come up (Docker Desktop / OrbStack
# both take 10-60s after login on a cold boot), then runs ./bin/up.sh.
#
# Logs land in ~/logs/n8n.{out,err}.log per the plist redirects.
set -uo pipefail

DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/Developer/onym-n8n}"
DOCKER_BIN="${DOCKER_BIN:-/usr/local/bin/docker}"
[ -x "$DOCKER_BIN" ] || DOCKER_BIN="/opt/homebrew/bin/docker"
[ -x "$DOCKER_BIN" ] || DOCKER_BIN="$(command -v docker)"

echo "==> $(date) onym-n8n launchd wrapper starting"
echo "==> DEV_ENV_DIR=$DEV_ENV_DIR"
echo "==> docker=$DOCKER_BIN"

cd "$DEV_ENV_DIR" || { echo "ERROR: $DEV_ENV_DIR not found" >&2; exit 1; }

# Wait for the docker daemon. `docker info` returns 0 once it's reachable;
# at cold boot that may take 30-60s while Docker Desktop initialises.
# Cap at 5 minutes — if it isn't up by then something is genuinely wrong.
echo "==> waiting for docker daemon (up to 5 min)"
for i in $(seq 1 60); do
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
        echo "==> docker ready after ${i}x5s"
        break
    fi
    sleep 5
done
if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    echo "ERROR: docker daemon never became ready — is Docker Desktop / OrbStack set to auto-start at login?" >&2
    exit 2
fi

# bin/up.sh renders the employees overlay + brings the whole stack up.
exec ./bin/up.sh
