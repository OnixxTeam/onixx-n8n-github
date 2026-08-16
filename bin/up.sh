#!/usr/bin/env bash
# Bring up this machine's half of the hybrid stack.
#
# Which half — and which compose files — comes entirely from .env
# (STACK_ROLE + COMPOSE_FILE). Run the same command on both machines:
#
#   ./bin/up.sh
#
# workstation: renders the employees overlay from employees.json, builds the
#              base image if missing, brings up manager-agent + employees,
#              then prints the manager's fan-out pubkey.
# vps:         brings up n8n. nginx and its certificate are managed outside
#              docker — see nginx/n8n.conf.example.
set -euo pipefail

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/_stack.sh"

stack_need_cmds docker jq
docker compose version >/dev/null 2>&1 \
    || stack_die "docker compose plugin missing"
docker info >/dev/null 2>&1 || stack_die "docker daemon not running"

# ---------------------------------------------------------------- vps half --
if [ "$STACK_ROLE" = "vps" ]; then
    section "VPS half — n8n"
    [ -f n8n.env ] || stack_die "n8n.env missing — cp n8n.env.example n8n.env and fill it in"
    stack_check_compose

    docker compose up -d
    echo
    docker compose ps

    cat <<'EOF'

Next:
  1. nginx in front of n8n (once):
       cp nginx/n8n.conf.example /etc/nginx/sites-available/n8n.conf
       # replace n8n.example.com with N8N_HOST from n8n.env
       ln -s /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/
       nginx -t && systemctl reload nginx
       certbot --nginx -d <N8N_HOST>
  2. Point n8n/secrets/ssh-manager-agent.json at the workstation:
       host = its Tailscale IP, port = 2200
  3. Create the n8n owner account at https://<N8N_HOST>/
  4. ./bin/n8n-deploy.sh
  5. ./bin/doctor.sh
EOF
    exit 0
fi

# -------------------------------------------------------- workstation half --
section "Workstation half — manager + employees"

for f in manager.env employees.json; do
    [ -f "$f" ] || stack_die "$f missing — copy it from ${f}.example and fill it in"
done

if [ "${MANAGER_SSH_BIND:-127.0.0.1}" = "127.0.0.1" ]; then
    warn "MANAGER_SSH_BIND is 127.0.0.1 — the VPS will NOT be able to reach the manager."
    info "Set it to this machine's Tailscale IP in .env:  tailscale ip -4"
fi

if ! docker image inspect onym-n8n/dev-env-base:latest >/dev/null 2>&1; then
    section "Building base image (one-time, several minutes)"
    docker build --platform=linux/arm64 \
        -t onym-n8n/dev-env-base:latest \
        -f Dockerfile.base "$STACK_DIR"
fi

section "Rendering docker-compose.employees.yml from employees.json"
./bin/render-employees-compose.sh

MISSING_TOKENS=()
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    ENV_FILE="employees/${LOGIN}.env"
    if grep -q "GITHUB_TOKEN=ghs_REPLACE_ME\|GITHUB_TOKEN=REPLACE_ME" "$ENV_FILE" 2>/dev/null; then
        MISSING_TOKENS+=("$ENV_FILE")
    fi
done < <(stack_employees)
if [ ${#MISSING_TOKENS[@]} -gt 0 ]; then
    warn "employee env files still hold placeholder tokens:"
    for f in "${MISSING_TOKENS[@]}"; do info "- $f"; done
fi

stack_check_compose

section "Building agent image + starting containers"
docker compose up -d --build
echo
docker compose ps

section "Waiting for first-run.sh to publish container pubkeys"
for c in $(stack_containers); do
    key=""
    for _ in $(seq 1 30); do
        key=$(docker logs "$c" 2>&1 | awk '/^ssh-ed25519/{print; exit}')
        [ -n "$key" ] && break
        sleep 1
    done
    if [ -n "$key" ]; then
        ok "$c  $key"
    else
        warn "$c — pubkey not printed yet, check: docker logs $c"
    fi
done

section "Manager fan-out pubkey"
FANOUT=$(docker logs onym-manager-agent 2>&1 \
    | awk '/MANAGER_SSH_PUBKEY \(paste/{flag=1; next} /end MANAGER_SSH_PUBKEY/{flag=0} flag' \
    | grep '^ssh-' | tail -1 || true)
if [ -n "$FANOUT" ]; then
    echo "$FANOUT"
else
    warn "not printed yet — try: docker logs onym-manager-agent"
fi

BIND="${MANAGER_SSH_BIND:-127.0.0.1}"
cat <<EOF

Next:
  1. Paste the fan-out pubkey above into MANAGER_SSH_PUBKEY in every
     employees/<login>.env, then restart the employees:
       docker compose restart $(stack_employees | sed 's/$/-agent/' | tr '\n' ' ')

  2. Log Claude in on every container (subscription, no API key) — the
     manager included, it runs claude for specialization routing:
$(for c in $(stack_containers); do echo "       docker exec -it -u agent $c claude"; done)

  3. On the VPS, point n8n/secrets/ssh-manager-agent.json at:
       host = $BIND    port = 2200

  4. ./bin/doctor.sh
EOF
