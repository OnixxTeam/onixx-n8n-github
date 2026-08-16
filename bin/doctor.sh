#!/usr/bin/env bash
# Verification checklist for this machine's half of the hybrid stack.
# Each check reports PASS/FAIL; the script exits non-zero on any failure.
# Which checks run comes from STACK_ROLE in .env — run it on both machines.
set -u

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/_stack.sh"

PASS=0
FAIL=0
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  [\033[32mPASS\033[0m] %s\n" "$label"
        PASS=$((PASS+1))
    else
        printf "  [\033[31mFAIL\033[0m] %s\n" "$label"
        FAIL=$((FAIL+1))
    fi
}
note() { printf "  [\033[34mINFO\033[0m] %s\n" "$*"; }

printf "\033[1mdoctor — role: %s\033[0m\n" "$STACK_ROLE"

# =========================================================== shared config ==
echo
echo "== config sanity =="
check "COMPOSE_FILE files all exist" stack_check_compose

if [ -r employees.json ]; then
    check "employees.json is valid JSON" jq -e . employees.json

    # The dispatcher resolves @-mentions with `.employees | has($login)`, so a
    # key that differs from the bot's GitHub login makes mention-routing a
    # silent no-op. Cheapest possible check for the most confusing failure.
    check "every employees.json key == its githubLogin" \
        jq -e '.employees | to_entries | all(.key == .value.githubLogin)' employees.json

    # Both defaults are read verbatim with no existence check — a stale login
    # sends the manager SSHing to a container that was never created.
    check "defaults.implementer names a real employee" \
        jq -e '.defaults.implementer as $d | .employees | has($d)' employees.json
    check "defaults.reviewer names a real employee" \
        jq -e '.defaults.reviewer as $d | .employees | has($d)' employees.json
fi

if [ -r n8n.env ] && [ -r employees.json ]; then
    # Only meaningful when both files sit on the same box; normally n8n.env
    # lives on the VPS and employees.json on the workstation.
    check "N8N_AGENT_LOGINS covers manager + every employee" bash -c '
        logins=$(awk -F= "/^N8N_AGENT_LOGINS=/{print \$2; exit}" n8n.env | tr -d "\"'"'"'" | tr "[:upper:]" "[:lower:]")
        want=$(jq -r "[.manager.githubLogin] + (.employees | to_entries | map(.value.githubLogin)) | .[]" employees.json | tr "[:upper:]" "[:lower:]")
        for w in $want; do
            case ",$logins," in *",$w,"*) ;; *) exit 1 ;; esac
        done'
fi

# ================================================================= VPS half ==
if [ "$STACK_ROLE" = "vps" ]; then
    echo
    echo "== containers =="
    check "onym-n8n running" bash -c \
        "test \"\$(docker inspect -f '{{.State.Running}}' onym-n8n 2>/dev/null)\" = 'true'"

    echo
    echo "== n8n health =="
    check "n8n loopback on 5678"  bash -c 'echo > /dev/tcp/127.0.0.1/5678'
    check "n8n /healthz"          curl -fsS http://127.0.0.1:5678/healthz
    # A live key that no longer matches n8n.env means the next recreate will
    # load the file's value and fail to decrypt every stored credential,
    # surfacing much later as "Credentials are not set" at workflow runtime.
    check "encryption key matches n8n.env" bash -c '
        live=$(docker exec onym-n8n printenv N8N_ENCRYPTION_KEY 2>/dev/null | tr -d "\r\n")
        file=$(awk -F= "/^N8N_ENCRYPTION_KEY=/{print \$2; exit}" n8n.env 2>/dev/null | tr -d "\r\n\"" )
        [ -n "$live" ] && [ -n "$file" ] && [ "$live" = "$file" ]'

    echo
    echo "== credentials =="
    for f in n8n/secrets/ssh-manager-agent.json n8n/secrets/github-manager-bot.json; do
        check "$f present" test -r "$f"
    done
    check "manager PAT filled in" bash -c \
        '! grep -q REPLACE_ME n8n/secrets/github-manager-bot.json'
    check "SSH credential points at a real host" bash -c \
        '! jq -r .data.host n8n/secrets/ssh-manager-agent.json | grep -q REPLACE_ME'

    echo
    echo "== reachability: n8n → manager =="
    MGR_HOST=$(jq -r '.data.host // ""' n8n/secrets/ssh-manager-agent.json 2>/dev/null)
    MGR_PORT=$(jq -r '.data.port // 22'  n8n/secrets/ssh-manager-agent.json 2>/dev/null)
    if [ -n "$MGR_HOST" ] && ! printf '%s' "$MGR_HOST" | grep -q REPLACE_ME; then
        note "target $MGR_HOST:$MGR_PORT"
        check "n8n container can open a socket to the manager" \
            docker exec onym-n8n node -e \
"const s=require('net').connect($MGR_PORT,'$MGR_HOST');s.setTimeout(5000);
s.on('connect',()=>{s.end();process.exit(0)});
s.on('timeout',()=>process.exit(1));s.on('error',()=>process.exit(1));"
    else
        note "skipped — set data.host in n8n/secrets/ssh-manager-agent.json first"
    fi

    echo
    echo "== public ingress (nginx) =="
    N8N_HOST_VAL=$(awk -F= '/^N8N_HOST=/{print $2; exit}' n8n.env 2>/dev/null | tr -d "\"' \r")
    if [ -n "$N8N_HOST_VAL" ]; then
        note "hostname $N8N_HOST_VAL"
        check "https://$N8N_HOST_VAL/healthz answers" \
            curl -fsS --max-time 10 "https://$N8N_HOST_VAL/healthz"
        # Without X-Forwarded-Proto n8n issues Secure cookies over what it
        # thinks is plain HTTP and the login page silently reloads forever.
        check "nginx forwards X-Forwarded-Proto" bash -c \
            "grep -q 'X-Forwarded-Proto' /etc/nginx/sites-enabled/*n8n* 2>/dev/null"
    else
        note "skipped — N8N_HOST not set in n8n.env"
    fi

    echo
    echo "---------------------------------------"
    printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
    exit
fi

# ========================================================= workstation half ==
EMPLOYEES=$(stack_employees)
AGENT_CONTAINERS=$(stack_containers)

echo
echo "== images =="
check "dev-env-base image present"  docker image inspect onym-n8n/dev-env-base:latest
check "dev-env-agent image present" docker image inspect onym-n8n/dev-env-agent:latest
BASE_ARCH=$(docker image inspect onym-n8n/dev-env-base:latest --format '{{.Architecture}}' 2>/dev/null | head -1)
AGENT_ARCH=$(docker image inspect onym-n8n/dev-env-agent:latest --format '{{.Architecture}}' 2>/dev/null | head -1)
note "base=${BASE_ARCH:-none} agent=${AGENT_ARCH:-none}"
check "base and agent images share an architecture" \
    bash -c "test -n '$BASE_ARCH' -a '$BASE_ARCH' = '$AGENT_ARCH'"

echo
echo "== containers =="
for c in $AGENT_CONTAINERS; do
    check "$c running" bash -c \
        "test \"\$(docker inspect -f '{{.State.Running}}' $c 2>/dev/null)\" = 'true'"
done

echo
echo "== published ports =="
BIND="${MANAGER_SSH_BIND:-127.0.0.1}"
note "manager sshd bind $BIND:2200"
check "manager sshd listening on $BIND:2200" bash -c "echo > /dev/tcp/$BIND/2200"
# Loopback means the VPS half can never open the SSH connection, so the
# whole pipeline dead-ends here even though every container looks healthy.
check "MANAGER_SSH_BIND is routable from the VPS (not 127.0.0.1)" \
    test "$BIND" != "127.0.0.1"
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    PORT=$(jq -r --arg l "$LOGIN" '.employees[$l].sshHostPort // empty' employees.json 2>/dev/null)
    [ -z "$PORT" ] && continue
    check "${LOGIN}-agent sshd on 127.0.0.1:$PORT" bash -c "echo > /dev/tcp/127.0.0.1/$PORT"
done <<<"$EMPLOYEES"

echo
echo "== in-container toolchains =="
for c in $AGENT_CONTAINERS; do
    check "$c: claude cli"  docker exec -u agent "$c" claude --version
    check "$c: gh cli"      docker exec -u agent "$c" gh --version
    check "$c: rustc"       docker exec -u agent "$c" rustc --version
done

echo
echo "== claude subscription login =="
# This deployment uses a Claude subscription, not ANTHROPIC_API_KEY. The
# OAuth token lands in ~/.claude/.credentials.json after `claude` → /login.
# Without it every dispatch fails at the point Claude is invoked.
for c in $AGENT_CONTAINERS; do
    check "$c: logged in (.credentials.json present)" \
        docker exec -u agent "$c" test -s /home/agent/.claude/.credentials.json
    check "$c: no ANTHROPIC_API_KEY in env" bash -c \
        "! docker exec $c printenv ANTHROPIC_API_KEY >/dev/null 2>&1"
done

echo
echo "== claude permission mode =="
# first-run.sh writes ~/.claude/settings.json with bypassPermissions on every
# boot. Without it headless `claude --print` stalls waiting for a TTY to
# confirm Edit/Write/Bash, and agent flows produce no diffs.
for c in $AGENT_CONTAINERS; do
    check "$c: bypassPermissions in settings.json" \
        docker exec -u agent "$c" \
            jq -e '.permissions.defaultMode == "bypassPermissions"' \
            /home/agent/.claude/settings.json
done

echo
echo "== github auth =="
for c in $AGENT_CONTAINERS; do
    check "$c: gh token persisted" docker exec -u agent "$c" test -s /home/agent/.gh-token
    check "$c: gh auth status ok" \
        docker exec -u agent "$c" env -u GITHUB_TOKEN -u GH_TOKEN gh auth status
done

echo
echo "== token identity matches employees.json =="
# The single most damaging silent misconfiguration. The dispatcher builds its
# bot-loop guard from the logins in employees.json, but each container
# actually comments as whoever its PAT belongs to. If the two disagree, the
# manager cannot recognise its own routing comment: that comment @-mentions
# an agent, which re-triggers the mention workflow, which posts another
# routing comment — an unbounded loop that looks like a working system until
# the thread fills up.
MGR_LOGIN=$(jq -r '.manager.githubLogin // ""' employees.json 2>/dev/null)
ACTUAL=$(docker exec -u agent onym-manager-agent \
    env -u GITHUB_TOKEN -u GH_TOKEN gh api user --jq .login 2>/dev/null | tr -d '\r')
note "manager: employees.json=$MGR_LOGIN  PAT identity=${ACTUAL:-unknown}"
check "manager PAT identity == manager.githubLogin" \
    bash -c "test -n '$ACTUAL' -a '$ACTUAL' = '$MGR_LOGIN'"

while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    WANT=$(jq -r --arg l "$LOGIN" '.employees[$l].githubLogin // ""' employees.json)
    GOT=$(docker exec -u agent "onym-${LOGIN}-agent" \
        env -u GITHUB_TOKEN -u GH_TOKEN gh api user --jq .login 2>/dev/null | tr -d '\r')
    note "$LOGIN: employees.json=$WANT  PAT identity=${GOT:-unknown}"
    check "$LOGIN PAT identity == githubLogin" \
        bash -c "test -n '$GOT' -a '$GOT' = '$WANT'"
done <<<"$EMPLOYEES"

echo
echo "== n8n-agent helpers =="
# Catches an image rebuilt without picking up new scripts, leaving agents
# with a stale set of /usr/local/bin entries.
for c in $AGENT_CONTAINERS; do
    check "$c: n8n-agent-react installed" \
        docker exec "$c" test -x /usr/local/bin/n8n-agent-react
done

echo
echo "== manager dispatcher =="
check "dispatcher present" \
    docker exec onym-manager-agent test -x /usr/local/bin/n8n-manager-dispatch
check "employees.json mounted" \
    docker exec onym-manager-agent test -r /etc/onym/employees.json
check "routing prompt mounted" \
    docker exec onym-manager-agent test -r /etc/onym/routing-prompt.tmpl
check "fan-out key generated" \
    docker exec -u agent onym-manager-agent test -f /home/agent/.ssh/manager-fanout

echo
echo "== manager → employee SSH =="
while IFS= read -r LOGIN; do
    [ -z "$LOGIN" ] && continue
    HOST=$(jq -r --arg l "$LOGIN" '.employees[$l].host' employees.json)
    PORT=$(jq -r --arg l "$LOGIN" '.employees[$l].port // 22' employees.json)
    check "manager → $LOGIN ($HOST:$PORT)" \
        docker exec -u agent onym-manager-agent \
            bash -c "ssh -i ~/.ssh/manager-fanout -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/manager-known-hosts -p $PORT agent@$HOST true"
done <<<"$EMPLOYEES"

echo
echo "---------------------------------------"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
