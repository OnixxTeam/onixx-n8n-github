#!/usr/bin/env bash
# Shared bootstrap for the hybrid stack scripts. SOURCE this, don't run it:
#
#   . "$(dirname "$0")/_stack.sh"
#
# It cd's to the repo root, loads .env, and exposes:
#
#   STACK_DIR            absolute repo root
#   STACK_ROLE           workstation | vps
#   stack_die MSG        print to stderr and exit 1
#   stack_need_role R    abort unless STACK_ROLE is R
#   stack_check_compose  verify every file in COMPOSE_FILE exists
#   stack_employees      print employee logins, one per line
#   stack_containers     print expected container names for this role
#   ok / warn / info     consistent output helpers
#
# No script hardcodes a compose filename — COMPOSE_FILE in .env decides,
# and docker compose reads it natively, so `docker compose ...` below needs
# no -f flags.

STACK_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR" || exit 1

if [ -t 1 ]; then
    _B=$'\033[1m'; _D=$'\033[2m'; _R=$'\033[31m'; _G=$'\033[32m'
    _Y=$'\033[33m'; _RS=$'\033[0m'
else
    _B=""; _D=""; _R=""; _G=""; _Y=""; _RS=""
fi
section() { printf "\n${_B}==> %s${_RS}\n" "$*"; }
ok()      { printf "  ${_G}OK${_RS}    %s\n" "$*"; }
warn()    { printf "  ${_Y}WARN${_RS}  %s\n" "$*" >&2; }
info()    { printf "  ${_D}%s${_RS}\n" "$*"; }
stack_die() { printf "  ${_R}ERROR${_RS} %s\n" "$*" >&2; exit 1; }

# ---- .env ------------------------------------------------------------------
if [ ! -r "$STACK_DIR/.env" ]; then
    stack_die ".env missing. Copy the template and pick this machine's role:
    cp .env.example .env
    \${EDITOR:-vim} .env"
fi
set -a
# shellcheck disable=SC1091
. "$STACK_DIR/.env"
set +a

STACK_ROLE="${STACK_ROLE:-}"
case "$STACK_ROLE" in
    workstation|vps) ;;
    "") stack_die "STACK_ROLE unset in .env — set it to 'workstation' or 'vps'" ;;
    *)  stack_die "STACK_ROLE='$STACK_ROLE' is not valid — use 'workstation' or 'vps'" ;;
esac

[ -n "${COMPOSE_FILE:-}" ] || stack_die "COMPOSE_FILE unset in .env — see .env.example"
STACK_SEP="${COMPOSE_PATH_SEPARATOR:-:}"

stack_need_role() {
    [ "$STACK_ROLE" = "$1" ] || stack_die \
        "$(basename "$0") only runs on the '$1' half; this machine's .env says STACK_ROLE=$STACK_ROLE"
}

# Every file named in COMPOSE_FILE must exist. Call AFTER rendering the
# generated employees overlay, not before.
stack_check_compose() {
    local f missing=()
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -f "$f" ] || missing+=("$f")
    done < <(printf '%s' "$COMPOSE_FILE" | tr "$STACK_SEP" '\n')
    if [ ${#missing[@]} -gt 0 ]; then
        stack_die "COMPOSE_FILE names files that don't exist: ${missing[*]}
    Fix COMPOSE_FILE in .env, or run ./bin/render-employees-compose.sh if the
    generated employees overlay is what's missing."
    fi
}

# ---- employees.json --------------------------------------------------------
stack_employees() {
    [ -r "$STACK_DIR/employees.json" ] || return 0
    jq -r '.employees | keys[]' "$STACK_DIR/employees.json" 2>/dev/null
}

stack_containers() {
    if [ "$STACK_ROLE" = "vps" ]; then
        echo "onym-n8n"
        return 0
    fi
    echo "onym-manager-agent"
    local login
    while IFS= read -r login; do
        [ -z "$login" ] && continue
        echo "onym-${login}-agent"
    done < <(stack_employees)
}

# ---- prerequisites ---------------------------------------------------------
stack_need_cmds() {
    local c missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || stack_die "missing command(s): ${missing[*]}"
}
