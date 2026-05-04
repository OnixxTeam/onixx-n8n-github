#!/bin/bash
# Bring up the dev-env compose stack. Builds the base + agent images
# first if they're missing, renders the per-employee compose overlay
# from employees.json, then brings up all services.
set -euo pipefail

DEV_ENV_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DEV_ENV_DIR"

REQUIRED_ENVS="manager.env n8n.env caddy.env employees.json"
for f in $REQUIRED_ENVS; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $DEV_ENV_DIR/$f missing — copy from ${f}.example and fill in" >&2
        exit 1
    fi
done

if ! docker image inspect onym-n8n/dev-env-base:latest >/dev/null 2>&1; then
    echo "==> building base image (one-time, ~3 min)"
    docker build --platform=linux/arm64 \
        -t onym-n8n/dev-env-base:latest \
        -f Dockerfile.base \
        "$DEV_ENV_DIR"
fi

echo "==> rendering docker-compose.employees.yml from employees.json"
./bin/render-employees-compose.sh

# Verify per-employee env files exist (renderer seeds blank ones; user
# fills in real GITHUB_TOKEN / ANTHROPIC_API_KEY / MANAGER_SSH_PUBKEY).
MISSING_TOKENS=()
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    ENV_FILE="employees/${LOGIN}.env"
    if grep -q "GITHUB_TOKEN=ghs_REPLACE_ME" "$ENV_FILE" 2>/dev/null; then
        MISSING_TOKENS+=("$ENV_FILE")
    fi
done < <(jq -r '.employees | keys[]' employees.json)
if [ ${#MISSING_TOKENS[@]} -gt 0 ]; then
    echo
    echo "WARN: these employee env files still have placeholder tokens:"
    for f in "${MISSING_TOKENS[@]}"; do echo "  - $f"; done
    echo "      Fill them in before the agents will be useful."
fi

echo "==> building agent image + starting stack"
docker compose -f docker-compose.dev.yml -f docker-compose.employees.yml \
    up -d --build

echo
echo "==> services"
docker compose -f docker-compose.dev.yml -f docker-compose.employees.yml ps

echo
echo "==> waiting for first-run.sh to emit container pubkeys (up to 30s each)"
ALL_CONTAINERS="onym-manager-agent"
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    ALL_CONTAINERS="$ALL_CONTAINERS onym-${LOGIN}-agent"
done < <(jq -r '.employees | keys[]' employees.json)

for c in $ALL_CONTAINERS; do
    key=""
    for _ in $(seq 1 30); do
        key=$(docker logs "$c" 2>&1 | awk '/^ssh-ed25519/{print; exit}')
        [ -n "$key" ] && break
        sleep 1
    done
    echo "--- $c id_ed25519 ---"
    [ -n "$key" ] && echo "$key" || echo "(pubkey not printed yet — check: docker logs $c)"
done

# The MANAGER also has a fan-out key; print it separately for clarity.
echo
echo "--- onym-manager-agent MANAGER_SSH_PUBKEY (paste into each employees/<login>.env) ---"
docker logs onym-manager-agent 2>&1 \
  | awk '/MANAGER_SSH_PUBKEY \(paste/{flag=1; next} /end MANAGER_SSH_PUBKEY/{flag=0} flag' \
  | tail -1 || echo "(not printed yet — try: docker logs onym-manager-agent)"

cat <<'EOF'

Next steps:
  1. Copy the MANAGER_SSH_PUBKEY line above into MANAGER_SSH_PUBKEY in
     every employees/<login>.env, then restart the employee containers:
       docker compose -f docker-compose.dev.yml \
                      -f docker-compose.employees.yml \
                      restart $(jq -r '.employees | keys[] | "\(.)-agent"' employees.json | tr '\n' ' ')

  2. (Mac-host build delegation only) Copy each container's id_ed25519
     pubkey above into /Users/stellar-builder/.ssh/authorized_keys on
     the Mac host, prefixed with:
       command="/Users/stellar-builder/bin/host-build-dispatch",restrict

  3. Public DNS + ports for Caddy:
       - Point N8N_PUBLIC_HOST (in caddy.env) at this host's public IP.
       - Open 80/tcp and 443/tcp+udp inbound at the macOS firewall.
     Watch Caddy issue the cert:
       docker compose -f docker-compose.dev.yml logs -f caddy

  4. Register the org webhook against the public Caddy URL:
       ./bin/gh-webhooks-sync.sh

  5. Push credentials + workflows into n8n:
       ./bin/n8n-deploy.sh

  6. Run ./bin/doctor.sh for the verification checklist.
EOF
