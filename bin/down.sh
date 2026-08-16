#!/usr/bin/env bash
# Stop this machine's half of the hybrid stack. Which half comes from .env.
#
#   ./bin/down.sh            # stop + remove containers, keep volumes
#   ./bin/down.sh --volumes  # also delete volumes (wipes agent homes, and
#                            # with them every container's Claude login;
#                            # on the VPS it wipes n8n's database)
set -euo pipefail

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/_stack.sh"

WIPE=0
case "${1:-}" in
    --volumes|-v) WIPE=1 ;;
    "")           ;;
    *)            stack_die "unknown argument: $1 (only --volumes is accepted)" ;;
esac

# The generated overlay is named in COMPOSE_FILE on the workstation; if it
# was deleted, re-render so compose can still see the employee services it
# needs to stop.
if [ "$STACK_ROLE" = "workstation" ] && [ ! -f docker-compose.employees.yml ]; then
    ./bin/render-employees-compose.sh >/dev/null
fi
stack_check_compose

if [ "$WIPE" -eq 1 ]; then
    if [ "$STACK_ROLE" = "vps" ]; then
        warn "This deletes the n8n-data volume: workflows, credentials and the"
        warn "owner account all go with it. Re-running ./bin/n8n-deploy.sh"
        warn "restores workflows and credentials, but not the owner account."
    else
        warn "This deletes every agent home volume: workspaces, generated SSH"
        warn "keys and each container's Claude subscription login. You will"
        warn "have to re-run \`claude\` /login in every container afterwards,"
        warn "and re-distribute the manager's new fan-out pubkey."
    fi
    printf "  Type 'yes' to continue: "
    read -r reply
    [ "$reply" = "yes" ] || stack_die "aborted"
    section "Stopping and removing containers + volumes"
    docker compose down --volumes
else
    section "Stopping and removing containers (volumes kept)"
    docker compose down
fi

ok "done"
