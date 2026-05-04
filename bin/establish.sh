#!/bin/bash
# bin/establish.sh — interactive setup wizard for the onym-n8n stack.
#
# IDEMPOTENT: re-runs read existing config from disk and present every
# previous answer as the default. Secrets are shown as ***<last 4>;
# pressing Enter keeps the saved value. Existing employees can be kept
# / edited / deleted individually.
#
# What the script does, in order:
#   1. Loads existing state from n8n.env / caddy.env / manager.env /
#      gh-webhooks.env / employees.json / employees/*.env if present.
#   2. Asks for stack-wide config (public domain, ACME email, GitHub
#      org, n8n basic auth, optional admin SSH pubkey) — defaults from
#      previous answers.
#   3. Asks for the manager bot's GitHub login + PAT + Anthropic key.
#   4. For each existing employee: keep / edit / delete. Then loops
#      asking for new ones.
#   5. Generates an n8n→manager SSH keypair (only if missing).
#   6. Writes EVERY config file (existing files backed up to
#      .bak.<timestamp>/).
#   7. Runs ./bin/up.sh.
#   8. Polls docker logs until the manager publishes its fan-out
#      pubkey, injects into every employees/<login>.env, restarts.
set -uo pipefail

DEV_ENV_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DEV_ENV_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$DEV_ENV_DIR/.bak.$STAMP"

# ---- Pretty print --------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi
section() { printf "\n${BOLD}${BLUE}==> %s${RESET}\n" "$*"; }
ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "  ${YELLOW}!${RESET} %s\n" "$*" >&2; }
fail()    { printf "  ${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }
info()    { printf "  ${DIM}%s${RESET}\n" "$*"; }

# ---- Quoting + redaction helpers -----------------------------------------
# Shell-safe single-quoted value for env files. Wraps in '...' and
# escapes any embedded ' as '\'' (close-quote, escaped-quote, re-open).
# Implemented char-by-char in pure bash so we don't depend on the
# notoriously fiddly ${var//pat/rep} quoting semantics, and so it's
# correct on bash 3.2.
sqq() {
    local v="$1" out="'" i ch
    for (( i=0; i<${#v}; i++ )); do
        ch="${v:i:1}"
        if [ "$ch" = "'" ]; then
            out+="'\\''"
        else
            out+="$ch"
        fi
    done
    out+="'"
    printf '%s' "$out"
}
# Redact a secret to ***<last 4>; show "(empty)" if blank.
redact() {
    local s="${1:-}"
    if [ -z "$s" ]; then printf '(empty)'; return; fi
    if [ ${#s} -le 4 ]; then printf '****'; return; fi
    printf '***%s' "${s: -4}"
}

# ---- Prompts -------------------------------------------------------------
ask() {
    local prompt="$1" default="${2:-}" reply=""
    if [ -n "$default" ]; then
        printf "${CYAN}?${RESET} %s ${DIM}[%s]${RESET} " "$prompt" "$default" >/dev/tty
    else
        printf "${CYAN}?${RESET} %s " "$prompt" >/dev/tty
    fi
    IFS= read -r reply </dev/tty || reply=""
    printf "%s" "${reply:-$default}"
}

ask_secret() {
    # Plain secret prompt (no saved default). Used only when there's
    # genuinely no prior value to keep.
    local prompt="$1" reply=""
    printf "${CYAN}?${RESET} %s ${DIM}(input hidden)${RESET} " "$prompt" >/dev/tty
    IFS= read -rs reply </dev/tty || reply=""
    printf "\n" >/dev/tty
    printf "%s" "$reply"
}

ask_secret_keep() {
    # Secret prompt with a saved value: shows ***last4 and Enter keeps.
    # ask_secret_keep "label" "$existing_value"
    local prompt="$1" existing="${2:-}" reply=""
    if [ -n "$existing" ]; then
        printf "${CYAN}?${RESET} %s ${DIM}[saved: %s — Enter to keep, or paste new]${RESET} " \
            "$prompt" "$(redact "$existing")" >/dev/tty
        IFS= read -rs reply </dev/tty || reply=""
        printf "\n" >/dev/tty
        printf "%s" "${reply:-$existing}"
    else
        ask_secret "$prompt"
    fi
}

ask_yn() {
    local prompt="$1" default="${2:-y}" reply="" lc=""
    while true; do
        local hint="[Y/n]"; [ "$default" = "n" ] && hint="[y/N]"
        printf "${CYAN}?${RESET} %s ${DIM}%s${RESET} " "$prompt" "$hint" >/dev/tty
        IFS= read -r reply </dev/tty || reply=""
        reply="${reply:-$default}"
        lc=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
        case "$lc" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     printf "  ${YELLOW}(answer y or n)${RESET}\n" >/dev/tty ;;
        esac
    done
}

ask_choice() {
    # ask_choice "Prompt" "default-letter" "k=keep e=edit d=delete"
    # Returns the chosen letter (lowercase).
    local prompt="$1" default="$2" choices="$3" reply="" lc=""
    while true; do
        printf "${CYAN}?${RESET} %s ${DIM}[%s] (default %s)${RESET} " \
            "$prompt" "$choices" "$default" >/dev/tty
        IFS= read -r reply </dev/tty || reply=""
        reply="${reply:-$default}"
        lc=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]' | cut -c1)
        case "$choices" in
            *"$lc"=*) printf "%s" "$lc"; return 0 ;;
            *)        printf "  ${YELLOW}(invalid choice)${RESET}\n" >/dev/tty ;;
        esac
    done
}

backup() {
    local src="$1"
    [ -e "$src" ] || return 0
    mkdir -p "$BACKUP_DIR/$(dirname "${src#$DEV_ENV_DIR/}")"
    cp -a "$src" "$BACKUP_DIR/${src#$DEV_ENV_DIR/}"
}

# ---- 0. Prereqs ----------------------------------------------------------
check_prereqs() {
    section "Checking prerequisites"
    local missing=()
    for cmd in docker jq openssl ssh-keygen awk; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! docker compose version >/dev/null 2>&1; then
        missing+=("docker-compose-plugin")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        fail "missing: ${missing[*]} — install via brew (or your package manager) and re-run."
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "docker daemon not running (start Docker Desktop / OrbStack and re-run)."
    fi
    # Writability check — silent write failures mid-script are the worst
    # kind of failure (we'd print "wrote X" lies and then up.sh would
    # blow up on missing files). Detect now.
    local probe="$DEV_ENV_DIR/.write-probe.$$"
    if ! ( : > "$probe" ) 2>/dev/null; then
        local owner
        owner=$(stat -f '%Su' "$DEV_ENV_DIR" 2>/dev/null \
              || stat -c '%U'  "$DEV_ENV_DIR" 2>/dev/null \
              || echo "?")
        fail "repo dir $DEV_ENV_DIR is not writable by $(whoami) (owned by $owner).
    Two ways to fix:
      A) Take ownership in place:
           sudo chown -R $(whoami) $DEV_ENV_DIR
      B) (Recommended) Clone to your home dir — /tmp is auto-wiped at every macOS reboot:
           git clone <repo-url> ~/Developer/onym-n8n
           cd ~/Developer/onym-n8n
           ./bin/establish.sh"
    fi
    rm -f "$probe"
    ok "all prerequisites present"
}

# ---- 1. Load existing state ----------------------------------------------
# All these vars are set to "" if not found in any existing file.
PREV_PUBLIC_HOST="" PREV_ACME_EMAIL="" PREV_GH_ORG=""
PREV_N8N_BASIC_USER="" PREV_N8N_BASIC_PASS="" PREV_N8N_ENC_KEY=""
PREV_HUMAN_QA="" PREV_MERGE_AUTH=""
PREV_ADMIN_PUBKEY=""
PREV_MGR_LOGIN="" PREV_MGR_PAT="" PREV_MGR_ANTHRO=""
PREV_N8N_MANAGER_PUBKEY="" PREV_N8N_MANAGER_PRIVKEY=""

# Source a single key from a sourceable env file safely (in a subshell).
read_env_key() {
    local file="$1" key="$2"
    [ -r "$file" ] || { printf ''; return; }
    ( set +u; set +e; . "$file" 2>/dev/null; eval "printf '%s' \"\${$key:-}\"" )
}

load_state() {
    section "Loading existing config (if any)"
    local found=0

    if [ -r caddy.env ]; then
        PREV_PUBLIC_HOST=$(read_env_key caddy.env N8N_PUBLIC_HOST)
        PREV_ACME_EMAIL=$(read_env_key  caddy.env ACME_EMAIL)
        found=1
    fi
    if [ -r n8n.env ]; then
        [ -z "$PREV_PUBLIC_HOST" ] && PREV_PUBLIC_HOST=$(read_env_key n8n.env N8N_HOST)
        PREV_N8N_BASIC_USER=$(read_env_key n8n.env N8N_BASIC_AUTH_USER)
        PREV_N8N_BASIC_PASS=$(read_env_key n8n.env N8N_BASIC_AUTH_PASSWORD)
        PREV_N8N_ENC_KEY=$(read_env_key   n8n.env N8N_ENCRYPTION_KEY)
        PREV_GH_ORG=$(read_env_key        n8n.env N8N_ALLOWED_ORG)
        PREV_MERGE_AUTH=$(read_env_key    n8n.env MERGE_AUTHORIZED_LOGINS)
        found=1
    fi
    if [ -r gh-webhooks.env ]; then
        [ -z "$PREV_GH_ORG" ] && PREV_GH_ORG=$(read_env_key gh-webhooks.env GH_ORG)
        found=1
    fi
    if [ -r manager.env ]; then
        PREV_MGR_PAT=$(read_env_key       manager.env GITHUB_TOKEN)
        PREV_MGR_ANTHRO=$(read_env_key    manager.env ANTHROPIC_API_KEY)
        PREV_ADMIN_PUBKEY=$(read_env_key  manager.env ADMIN_SSH_PUBKEY)
        PREV_N8N_MANAGER_PUBKEY=$(read_env_key manager.env N8N_SSH_PUBKEY)
        # GIT_COMMITTER_NAME doubles as a hint for the manager login.
        local committer
        committer=$(read_env_key manager.env GIT_COMMITTER_NAME)
        [ -n "$committer" ] && PREV_MGR_LOGIN="$committer"
        found=1
    fi
    if [ -r employees.json ]; then
        PREV_MGR_LOGIN=$(jq -r '.manager.githubLogin // ""' employees.json)
        [ -z "$PREV_HUMAN_QA" ]   && PREV_HUMAN_QA=$(jq -r '.defaults.humanQa // ""' employees.json)
        [ -z "$PREV_MERGE_AUTH" ] && PREV_MERGE_AUTH=$(jq -r '.mergeAuthorizedLogins // [] | join(",")' employees.json)
        found=1
    fi
    if [ -r n8n/secrets/n8n-manager-key ]; then
        PREV_N8N_MANAGER_PRIVKEY=$(<n8n/secrets/n8n-manager-key)
        found=1
    fi

    if [ "$found" -eq 1 ]; then
        ok "loaded prior state — defaults will be prefilled (Enter to keep)"
    else
        ok "no prior state — fresh setup"
    fi
}

# ---- 2. Stack-wide config ------------------------------------------------
gather_stack() {
    section "Stack-wide configuration"
    info "Defaults shown in [brackets] are loaded from existing config files."
    PUBLIC_HOST=$(ask "Public hostname for n8n (DNS A record points here)" \
                      "${PREV_PUBLIC_HOST:-n8n.example.com}")
    ACME_EMAIL=$(ask "Email for Let's Encrypt registration (optional)" \
                     "$PREV_ACME_EMAIL")
    GH_ORG=$(ask "GitHub organization name (members can summon agents)" \
                 "${PREV_GH_ORG:-onymchat}")
    N8N_BASIC_USER=$(ask "n8n UI basic-auth username" \
                         "${PREV_N8N_BASIC_USER:-admin}")
    N8N_BASIC_PASS=$(ask_secret_keep "n8n UI basic-auth password" \
                                     "$PREV_N8N_BASIC_PASS")
    [ -z "$N8N_BASIC_PASS" ] && fail "n8n basic-auth password cannot be empty"
    HUMAN_QA=$(ask "Human GitHub login who receives smoke-test issues" \
                   "$PREV_HUMAN_QA")
    [ -z "$HUMAN_QA" ] && fail "human QA login cannot be empty"
    MERGE_AUTH=$(ask "Comma-separated logins authorised to /merge" \
                     "${PREV_MERGE_AUTH:-$HUMAN_QA}")
    info "Optional: an admin SSH pubkey for direct interactive shell access"
    info "to the manager + employees (bypasses dispatch — useful for debugging)."
    ADMIN_PUBKEY=$(ask "Admin SSH pubkey (paste full ssh-ed25519 line, blank to skip)" \
                       "$PREV_ADMIN_PUBKEY")
}

# ---- 3. Manager credentials ----------------------------------------------
gather_manager() {
    section "Manager bot credentials"
    info "The manager is the GitHub identity that posts 'Routed to @<employee>' comments."
    MGR_LOGIN=$(ask "Manager GitHub login" "${PREV_MGR_LOGIN:-onym-manager}")
    MGR_PAT=$(ask_secret_keep "Manager GitHub PAT (fine-grained, scoped to $GH_ORG)" \
                              "$PREV_MGR_PAT")
    [ -z "$MGR_PAT" ] && fail "manager PAT cannot be empty"
    MGR_ANTHRO=$(ask_secret_keep "Anthropic API key for the manager (used for routing inference)" \
                                 "$PREV_MGR_ANTHRO")
    [ -z "$MGR_ANTHRO" ] && fail "Anthropic API key cannot be empty"
}

# ---- 4. Employees --------------------------------------------------------
declare -a EMP_LOGIN EMP_GH EMP_SPEC EMP_TAGS EMP_PORT EMP_PAT EMP_ANTHRO
DEFAULT_IMPL=""
DEFAULT_REV=""

load_existing_employees() {
    [ -r employees.json ] || return 0
    local i=0 login
    while IFS= read -r login; do
        [ -z "$login" ] && continue
        EMP_LOGIN[i]="$login"
        EMP_GH[i]=$(jq -r --arg l "$login"     '.employees[$l].githubLogin // ""'   employees.json)
        EMP_SPEC[i]=$(jq -r --arg l "$login"   '.employees[$l].specialization // ""' employees.json)
        EMP_TAGS[i]=$(jq -r --arg l "$login"   '(.employees[$l].tags // []) | join(",")' employees.json)
        EMP_PORT[i]=$(jq -r --arg l "$login"   '.employees[$l].sshHostPort // ""'   employees.json)
        # Per-employee secrets live in employees/<login>.env.
        if [ -r "employees/${login}.env" ]; then
            EMP_PAT[i]=$(read_env_key    "employees/${login}.env" GITHUB_TOKEN)
            EMP_ANTHRO[i]=$(read_env_key "employees/${login}.env" ANTHROPIC_API_KEY)
        else
            EMP_PAT[i]=""; EMP_ANTHRO[i]=""
        fi
        i=$((i+1))
    done < <(jq -r '.employees | keys[]' employees.json 2>/dev/null)
    DEFAULT_IMPL=$(jq -r '.defaults.implementer // ""' employees.json)
    DEFAULT_REV=$(jq -r  '.defaults.reviewer // ""'   employees.json)
}

# Drop the i'th employee from all the parallel arrays.
emp_drop() {
    local idx="$1" i n="${#EMP_LOGIN[@]}"
    local -a NL NG NS NT NP NPAT NA
    for ((i=0; i<n; i++)); do
        [ "$i" -eq "$idx" ] && continue
        NL+=("${EMP_LOGIN[i]}");  NG+=("${EMP_GH[i]}")
        NS+=("${EMP_SPEC[i]}");   NT+=("${EMP_TAGS[i]}")
        NP+=("${EMP_PORT[i]}");   NPAT+=("${EMP_PAT[i]}"); NA+=("${EMP_ANTHRO[i]}")
    done
    EMP_LOGIN=("${NL[@]:-}"); EMP_GH=("${NG[@]:-}")
    EMP_SPEC=("${NS[@]:-}");  EMP_TAGS=("${NT[@]:-}")
    EMP_PORT=("${NP[@]:-}");  EMP_PAT=("${NPAT[@]:-}"); EMP_ANTHRO=("${NA[@]:-}")
}

# Edit the i'th employee in-place, prompting with current values as defaults.
emp_edit() {
    local idx="$1"
    local login="${EMP_LOGIN[idx]}"
    info "Editing $login (Enter on each prompt to keep current)"
    EMP_GH[idx]=$(ask     "  GitHub login for $login"  "${EMP_GH[idx]}")
    EMP_SPEC[idx]=$(ask   "  Specialization"           "${EMP_SPEC[idx]}")
    EMP_TAGS[idx]=$(ask   "  Tags (csv)"               "${EMP_TAGS[idx]}")
    EMP_PORT[idx]=$(ask   "  Loopback SSH port"        "${EMP_PORT[idx]}")
    EMP_PAT[idx]=$(ask_secret_keep    "  GitHub PAT for @${EMP_GH[idx]}" "${EMP_PAT[idx]}")
    EMP_ANTHRO[idx]=$(ask_secret_keep "  Anthropic API key for $login"   "${EMP_ANTHRO[idx]}")
}

# Append a new employee. Returns 0 if added, 1 if user gave empty login.
emp_add() {
    local count="${#EMP_LOGIN[@]}" next_port=2201
    if [ "$count" -gt 0 ]; then
        # Default the next port to one above the highest existing port.
        local p max=2200
        for p in "${EMP_PORT[@]:-}"; do
            [ -z "$p" ] && continue
            [ "$p" -gt "$max" ] && max="$p"
        done
        next_port=$((max+1))
    fi
    local login gh spec tags port pat anthro
    login=$(ask "Employee login (the JSON key in employees.json)" "")
    [ -z "$login" ] && return 1
    if ! [[ "$login" =~ ^[a-z][a-z0-9-]*$ ]]; then
        warn "login must be lowercase, alnum + dashes, starting with a letter — try again"
        return 2
    fi
    local existing
    for existing in "${EMP_LOGIN[@]:-}"; do
        if [ "$existing" = "$login" ]; then
            warn "$login already exists — pick a different login or edit the existing one"
            return 2
        fi
    done
    gh=$(ask "  GitHub login for $login" "$login")
    spec=$(ask "  Specialization (free text — Claude reads this when routing)" \
               "general-purpose engineer")
    tags=$(ask "  Tags (comma-separated, used as routing hints)" "")
    port=$(ask "  Loopback SSH port for direct admin access (blank for none)" \
               "$next_port")
    pat=$(ask_secret "  GitHub PAT for @$gh")
    [ -z "$pat" ] && { warn "PAT can't be empty — try again"; return 2; }
    anthro=$(ask_secret "  Anthropic API key for $login")
    [ -z "$anthro" ] && { warn "Anthropic key can't be empty — try again"; return 2; }
    EMP_LOGIN+=("$login"); EMP_GH+=("$gh"); EMP_SPEC+=("$spec")
    EMP_TAGS+=("$tags"); EMP_PORT+=("$port"); EMP_PAT+=("$pat"); EMP_ANTHRO+=("$anthro")
    if [ -z "$DEFAULT_IMPL" ]; then
        ask_yn "  Make $login the default implementer?" "y" && DEFAULT_IMPL="$login"
    fi
    if [ "$login" != "$DEFAULT_IMPL" ] && [ -z "$DEFAULT_REV" ]; then
        ask_yn "  Make $login the default reviewer?" "y" && DEFAULT_REV="$login"
    fi
    ok "added $login (@$gh)"
    return 0
}

gather_employees() {
    section "Employees"
    load_existing_employees

    # Phase 1: review existing employees, allow keep/edit/delete each.
    if [ "${#EMP_LOGIN[@]}" -gt 0 ]; then
        info "Found ${#EMP_LOGIN[@]} existing employee(s). Decide what to do with each."
        local i=0
        while [ "$i" -lt "${#EMP_LOGIN[@]}" ]; do
            printf "\n  ${BOLD}%s${RESET} (@%s) port=%s spec=\"%s\" tags=\"%s\"\n" \
                "${EMP_LOGIN[i]}" "${EMP_GH[i]}" "${EMP_PORT[i]:-none}" \
                "${EMP_SPEC[i]}" "${EMP_TAGS[i]}"
            printf "    PAT=%s, Anthropic=%s\n" \
                "$(redact "${EMP_PAT[i]}")" "$(redact "${EMP_ANTHRO[i]}")"
            local choice
            choice=$(ask_choice "Action?" "k" "k=keep e=edit d=delete")
            case "$choice" in
                k) i=$((i+1));;
                e) emp_edit "$i"; i=$((i+1));;
                d) emp_drop "$i"
                   # Clear default-* if the deleted employee was a default.
                   [ "$DEFAULT_IMPL" = "${EMP_LOGIN[i]:-}" ] && DEFAULT_IMPL=""
                   [ "$DEFAULT_REV"  = "${EMP_LOGIN[i]:-}" ] && DEFAULT_REV=""
                   ok "deleted";;
            esac
        done
    fi

    # Phase 2: add new employees.
    info "Add new employees (blank login to stop)."
    while true; do
        printf "\n${BOLD}--- New employee ---${RESET}\n"
        emp_add
        case "$?" in
            0) ask_yn "Add another?" "y" || break ;;
            1) [ "${#EMP_LOGIN[@]}" -eq 0 ] && warn "you need at least one employee" && continue
               break ;;
            *) continue ;;
        esac
    done

    # Sanity: pick defaults if missing.
    [ -z "$DEFAULT_IMPL" ] && DEFAULT_IMPL="${EMP_LOGIN[0]}"
    [ -z "$DEFAULT_REV" ]  && DEFAULT_REV="$DEFAULT_IMPL"
}

# ---- 5. Confirmation -----------------------------------------------------
confirm() {
    section "Summary (review before writing files)"
    printf "  ${BOLD}Public:${RESET}     https://%s/\n" "$PUBLIC_HOST"
    printf "  ${BOLD}ACME email:${RESET} %s\n" "${ACME_EMAIL:-(none)}"
    printf "  ${BOLD}GitHub org:${RESET} %s\n" "$GH_ORG"
    printf "  ${BOLD}Manager:${RESET}    @%s  (PAT %s, Anthropic %s)\n" \
        "$MGR_LOGIN" "$(redact "$MGR_PAT")" "$(redact "$MGR_ANTHRO")"
    printf "  ${BOLD}Default impl:${RESET}    %s\n" "$DEFAULT_IMPL"
    printf "  ${BOLD}Default reviewer:${RESET} %s\n" "$DEFAULT_REV"
    printf "  ${BOLD}Human QA:${RESET}        %s\n" "$HUMAN_QA"
    printf "  ${BOLD}/merge allowed:${RESET}  %s\n" "$MERGE_AUTH"
    printf "  ${BOLD}Employees (%d):${RESET}\n" "${#EMP_LOGIN[@]}"
    local i
    for i in "${!EMP_LOGIN[@]}"; do
        printf "    - %s (@%s) port=%s PAT=%s Anthropic=%s\n" \
            "${EMP_LOGIN[i]}" "${EMP_GH[i]}" "${EMP_PORT[i]:-none}" \
            "$(redact "${EMP_PAT[i]}")" "$(redact "${EMP_ANTHRO[i]}")"
    done
    printf "\n"
    ask_yn "Write all config files and (re-)boot the stack?" "y" || fail "aborted by user"
}

# ---- 6. Generate or reuse n8n→manager SSH keypair ------------------------
gen_n8n_manager_key() {
    section "n8n → manager-agent SSH keypair"
    mkdir -p n8n/secrets
    chmod 700 n8n/secrets
    local key=n8n/secrets/n8n-manager-key
    if [ -f "$key" ] && [ -f "${key}.pub" ]; then
        N8N_MANAGER_PUBKEY=$(<"${key}.pub")
        N8N_MANAGER_PRIVKEY=$(<"$key")
        ok "reusing existing $key"
    else
        backup "$key"; backup "${key}.pub"
        rm -f "$key" "${key}.pub"
        ssh-keygen -t ed25519 -N "" -f "$key" -C "n8n@manager-agent" -q
        chmod 600 "$key"
        N8N_MANAGER_PUBKEY=$(<"${key}.pub")
        N8N_MANAGER_PRIVKEY=$(<"$key")
        ok "generated $key + ${key}.pub"
    fi
}

# ---- 7. File writers (use sqq() for shell-safe quoting) ------------------
write_caddy_env() {
    backup caddy.env
    {
        echo "# Generated by bin/establish.sh on $STAMP. Edit by hand any time."
        echo "N8N_PUBLIC_HOST=$(sqq "$PUBLIC_HOST")"
        echo "ACME_EMAIL=$(sqq "$ACME_EMAIL")"
    } > caddy.env
    chmod 600 caddy.env
    ok "wrote caddy.env"
}

write_n8n_env() {
    backup n8n.env
    local enc_key="${PREV_N8N_ENC_KEY:-$(openssl rand -hex 32)}"
    {
        echo "# Generated by bin/establish.sh on $STAMP. Edit by hand any time."
        echo "# WARNING: changing N8N_ENCRYPTION_KEY after creating credentials in"
        echo "# the n8n UI will lose access to those credentials."
        echo "N8N_ENCRYPTION_KEY=$(sqq "$enc_key")"
        echo "GENERIC_TIMEZONE=UTC"
        echo "N8N_BASIC_AUTH_ACTIVE=true"
        echo "N8N_BASIC_AUTH_USER=$(sqq "$N8N_BASIC_USER")"
        echo "N8N_BASIC_AUTH_PASSWORD=$(sqq "$N8N_BASIC_PASS")"
        echo "N8N_HOST=$(sqq "$PUBLIC_HOST")"
        echo "WEBHOOK_URL=$(sqq "https://$PUBLIC_HOST/")"
        echo "N8N_DIAGNOSTICS_ENABLED=false"
        echo "N8N_BLOCK_ENV_ACCESS_IN_NODE=false"
        echo "N8N_ALLOWED_ORG=$(sqq "$GH_ORG")"
        echo "MERGE_AUTHORIZED_LOGINS=$(sqq "$MERGE_AUTH")"
    } > n8n.env
    chmod 600 n8n.env
    ok "wrote n8n.env"
}

write_gh_webhooks_env() {
    backup gh-webhooks.env
    {
        echo "# Generated by bin/establish.sh on $STAMP. Edit by hand any time."
        echo "GH_ORG=$(sqq "$GH_ORG")"
        echo "WEBHOOK_BASE_URL=$(sqq "https://$PUBLIC_HOST")"
    } > gh-webhooks.env
    chmod 600 gh-webhooks.env
    ok "wrote gh-webhooks.env"
}

write_manager_env() {
    backup manager.env
    {
        echo "# Generated by bin/establish.sh on $STAMP. Edit by hand any time."
        echo "GITHUB_TOKEN=$(sqq "$MGR_PAT")"
        echo "ANTHROPIC_API_KEY=$(sqq "$MGR_ANTHRO")"
        echo "GIT_COMMITTER_NAME=$(sqq "$MGR_LOGIN")"
        echo "GIT_COMMITTER_EMAIL=$(sqq "${MGR_LOGIN}@bots.onym-n8n.local")"
        echo "N8N_SSH_PUBKEY=$(sqq "$N8N_MANAGER_PUBKEY")"
        echo "ADMIN_SSH_PUBKEY=$(sqq "$ADMIN_PUBKEY")"
        echo "MAC_HOST=host.docker.internal"
        echo "MAC_HOST_USER=$(sqq "$(whoami)")"
        echo "MAC_HOST_PORT=22"
    } > manager.env
    chmod 600 manager.env
    ok "wrote manager.env"
}

write_employees_json() {
    backup employees.json
    local emp_json='{}'
    local i
    for i in "${!EMP_LOGIN[@]}"; do
        local tags_json='[]'
        if [ -n "${EMP_TAGS[i]}" ]; then
            tags_json=$(printf '%s' "${EMP_TAGS[i]}" \
                | jq -Rs 'split(",") | map(gsub("^\\s+|\\s+$";""))')
        fi
        local port_json="null"
        [ -n "${EMP_PORT[i]}" ] && port_json="${EMP_PORT[i]}"
        emp_json=$(printf '%s' "$emp_json" | jq \
            --arg login "${EMP_LOGIN[i]}" \
            --arg gh "${EMP_GH[i]}" \
            --arg spec "${EMP_SPEC[i]}" \
            --argjson tags "$tags_json" \
            --argjson port "$port_json" \
            '. + { ($login): ({
                host: ($login + "-agent"),
                port: 22,
                user: "agent",
                githubLogin: $gh,
                specialization: $spec,
                tags: $tags
              } + (if $port == null then {} else {sshHostPort: $port} end))
            }')
    done
    local merge_json
    merge_json=$(printf '%s' "$MERGE_AUTH" \
        | jq -Rs 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')
    jq -n \
        --arg mgr "$MGR_LOGIN" \
        --argjson emps "$emp_json" \
        --arg impl "$DEFAULT_IMPL" \
        --arg rev "$DEFAULT_REV" \
        --arg qa "$HUMAN_QA" \
        --argjson merge "$merge_json" \
        '{
          manager: { host: "manager-agent", port: 22, user: "agent", githubLogin: $mgr },
          employees: $emps,
          defaults: { implementer: $impl, reviewer: $rev, humanQa: $qa },
          mergeAuthorizedLogins: $merge
        }' > employees.json
    chmod 600 employees.json
    ok "wrote employees.json"
}

write_employee_envs() {
    mkdir -p employees
    chmod 700 employees
    local i
    for i in "${!EMP_LOGIN[@]}"; do
        local login="${EMP_LOGIN[i]}"
        local target="employees/${login}.env"
        # Preserve any MANAGER_SSH_PUBKEY that was already in the file —
        # the propagation step at the end will refresh it from running
        # docker logs anyway, but on a re-run with no manager restart
        # this avoids briefly blanking it.
        local prev_mgr_key=""
        [ -r "$target" ] && prev_mgr_key=$(read_env_key "$target" MANAGER_SSH_PUBKEY)
        backup "$target"
        {
            echo "# Generated by bin/establish.sh on $STAMP. Edit by hand any time."
            echo "GITHUB_TOKEN=$(sqq "${EMP_PAT[i]}")"
            echo "ANTHROPIC_API_KEY=$(sqq "${EMP_ANTHRO[i]}")"
            echo "GIT_COMMITTER_NAME=$(sqq "${EMP_GH[i]}")"
            echo "GIT_COMMITTER_EMAIL=$(sqq "${EMP_GH[i]}@bots.onym-n8n.local")"
            echo "MANAGER_SSH_PUBKEY=$(sqq "$prev_mgr_key")"
            echo "ADMIN_SSH_PUBKEY=$(sqq "$ADMIN_PUBKEY")"
            echo "MAC_HOST=host.docker.internal"
            echo "MAC_HOST_USER=$(sqq "$(whoami)")"
            echo "MAC_HOST_PORT=22"
        } > "$target"
        chmod 600 "$target"
        ok "wrote $target"
    done
}

write_n8n_credentials() {
    mkdir -p n8n/secrets
    chmod 700 n8n/secrets
    backup n8n/secrets/ssh-manager-agent.json
    backup n8n/secrets/github-manager-bot.json

    local priv_json
    priv_json=$(printf '%s' "$N8N_MANAGER_PRIVKEY" | jq -Rs .)
    jq -n --argjson priv "$priv_json" '{
      name: "manager-agent SSH",
      type: "sshPrivateKey",
      data: {
        host: "manager-agent",
        port: 22,
        username: "agent",
        privateKey: $priv,
        passphrase: ""
      }
    }' > n8n/secrets/ssh-manager-agent.json
    chmod 600 n8n/secrets/ssh-manager-agent.json
    ok "wrote n8n/secrets/ssh-manager-agent.json"

    jq -n --arg user "$MGR_LOGIN" --arg tok "$MGR_PAT" '{
      name: "manager GitHub",
      type: "githubApi",
      data: { server: "https://api.github.com", user: $user, accessToken: $tok }
    }' > n8n/secrets/github-manager-bot.json
    chmod 600 n8n/secrets/github-manager-bot.json
    ok "wrote n8n/secrets/github-manager-bot.json"
}

# ---- 8. Boot stack -------------------------------------------------------
boot_stack() {
    section "Booting stack (./bin/up.sh)"
    info "First-time builds can take 3-5 minutes. Subsequent runs are fast."
    if ! ./bin/up.sh; then
        fail "./bin/up.sh failed — fix the error above and re-run establish.sh, OR run up.sh manually after fixing."
    fi
}

# ---- 9. Wait for manager fan-out pubkey ----------------------------------
wait_for_manager_pubkey() {
    section "Waiting for manager-agent to publish its fan-out pubkey"
    info "(this is the key the manager uses to SSH to each employee)"
    local key="" tries=60 i
    for i in $(seq 1 "$tries"); do
        key=$(docker logs onym-manager-agent 2>&1 \
              | awk '/MANAGER_SSH_PUBKEY \(paste/{flag=1; next} /end MANAGER_SSH_PUBKEY/{flag=0} flag' \
              | grep '^ssh-' | tail -1)
        if [ -n "$key" ]; then
            ok "captured pubkey ($(printf '%s' "$key" | head -c 40)…)"
            MANAGER_FANOUT_PUBKEY="$key"
            return 0
        fi
        sleep 2
    done
    fail "manager fan-out pubkey did not appear in logs after $((tries*2))s — check: docker logs onym-manager-agent"
}

# ---- 10. Inject pubkey into each employee env + restart ------------------
propagate_manager_key() {
    section "Wiring manager → employees"
    local i
    for i in "${!EMP_LOGIN[@]}"; do
        local target="employees/${EMP_LOGIN[i]}.env"
        local tmp
        tmp=$(mktemp)
        awk -v key="$MANAGER_FANOUT_PUBKEY" -v q="'" '
            /^MANAGER_SSH_PUBKEY=/ { print "MANAGER_SSH_PUBKEY=" q key q; next }
            { print }
        ' "$target" > "$tmp" && mv "$tmp" "$target"
        chmod 600 "$target"
        ok "set MANAGER_SSH_PUBKEY in $target"
    done

    section "Restarting employees so first-run.sh trusts the manager"
    local svcs=()
    for login in "${EMP_LOGIN[@]}"; do
        svcs+=("${login}-agent")
    done
    docker compose -f docker-compose.dev.yml -f docker-compose.employees.yml \
        restart "${svcs[@]}" >/dev/null
    ok "restarted: ${svcs[*]}"
}

# ---- 11. Final summary ---------------------------------------------------
print_next_steps() {
    section "Done — next steps"
    cat <<EOF

  1. ${BOLD}DNS${RESET}: ensure $PUBLIC_HOST resolves to this host's public IP.
  2. ${BOLD}Firewall${RESET}: open 80/tcp and 443/tcp+udp inbound.
  3. ${BOLD}Watch Caddy issue the cert${RESET}:
       docker compose -f docker-compose.dev.yml logs -f caddy
     Look for: "certificate obtained successfully"
  4. ${BOLD}Create the n8n owner account${RESET} at:
       https://$PUBLIC_HOST/
  5. ${BOLD}Push workflows + credentials into n8n${RESET}:
       ./bin/n8n-deploy.sh
  6. ${BOLD}Register the org-level GitHub webhook${RESET}:
       ./bin/gh-webhooks-sync.sh
  7. ${BOLD}Verify${RESET}:
       ./bin/doctor.sh

  Backups of any pre-existing config files (if writes happened) are in:
       $BACKUP_DIR

  Re-run ${BOLD}./bin/establish.sh${RESET} any time to edit answers — your
  previous values will be loaded as defaults and secrets shown as
  ***<last4>; press Enter at any prompt to keep what's already saved.
EOF
}

# ---- main ----------------------------------------------------------------
main() {
    printf "${BOLD}onym-n8n establish.sh${RESET}  ${DIM}(repo: $DEV_ENV_DIR)${RESET}\n"
    check_prereqs
    load_state
    gather_stack
    gather_manager
    gather_employees
    confirm
    # Strict mode for the file-writing phase — any redirect / chmod /
    # mkdir failure aborts immediately with a clear stack trace, instead
    # of printing fake "wrote X" successes and corrupting state.
    set -e
    gen_n8n_manager_key
    section "Writing config files (existing files backed up)"
    mkdir -p "$BACKUP_DIR"
    write_caddy_env
    write_n8n_env
    write_gh_webhooks_env
    write_manager_env
    write_employees_json
    write_employee_envs
    write_n8n_credentials
    set +e
    boot_stack
    wait_for_manager_pubkey
    propagate_manager_key
    set +e   # leave strict mode so the next-steps printer can run freely
    print_next_steps
}

main "$@"
