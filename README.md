# onixx-n8n-github

Self-hosted n8n + a **manager-mediated agent fleet**: one `manager-agent`
container that fans out to N `<login>-agent` employee containers. Each
employee has its own GitHub identity and a free-text *specialization*.
The manager parses every inbound webhook, picks the best employee
(explicit `@`-mention → assignment → claude-routed by specialization),
posts a visible "routed to @<employee>" comment as itself, then SSHes
to the chosen employee to run the actual work.

The headline flow: open or assign an issue in any repo in your org → n8n
forwards it to `manager-agent` → manager picks an employee → that
employee opens a PR → review is auto-requested from the default reviewer
employee → comments / `/build` / `/merge` slash commands round-trip back
through the manager.

## Credits

Originally written by **Rinat Enikeev** ([@rinat-enikeev](https://github.com/rinat-enikeev))
as [`onymchat/onym-n8n`](https://github.com/onymchat/onym-n8n). This is an
independent copy — not a GitHub fork — maintained by the Onixx team. All
of the orchestration design, the workflows and the agent scripts are the
original author's work; the changes described below are deployment-level
adaptations.

Upstream is kept as a git remote so improvements can be pulled in:

```bash
git remote -v
# origin    git@github.com:OnixxTeam/onixx-n8n-github.git
# upstream  git@github.com:onymchat/onym-n8n.git

git fetch upstream && git log --oneline HEAD..upstream/main
```

Upstream ships no LICENSE file. Check with the original author before
redistributing.

## How this copy differs from upstream

| | Upstream | Here |
|---|---|---|
| Deployment | Single host runs everything | **Split**: n8n on a small VPS, agents on a workstation |
| TLS / ingress | Caddy container, automatic Let's Encrypt | **The host's own nginx** + certbot |
| n8n → manager link | Docker network, hostname `manager-agent` | **Tailscale**, `100.x.y.z:2200` |
| Claude auth | `ANTHROPIC_API_KEY` per agent | **Claude subscription**, logged in once per container |
| Compose files | `docker-compose.dev.yml` (+ generated employees overlay) | **replaced** by `docker-compose.vps.yml` + `docker-compose.mac.yml` |

The Caddy path is gone from this copy: `docker-compose.dev.yml`, `Caddyfile`
and `caddy.env.example` were deleted, since nginx already terminates TLS on
the VPS. They remain in upstream's history if you ever need them back:

```bash
git show upstream/main:docker-compose.dev.yml
```

Nothing under `bin/` names a compose file any more. Each machine gets a
`.env` declaring `STACK_ROLE` (`workstation` or `vps`) and `COMPOSE_FILE`;
every script sources `bin/_stack.sh`, which loads it, refuses to run on the
wrong half, and lets `docker compose` resolve the files natively — so plain
`docker compose ps` works in this directory too, with no `-f` flags.

### Why split the stack

GitHub only delivers webhooks to a publicly reachable HTTPS endpoint with
a valid certificate (`bin/gh-webhooks-sync.sh` pins `insecure_ssl: "0"`),
which a workstation behind NAT cannot offer. Conversely a small VPS has
nowhere near the RAM an agent container needs once Claude Code is running.
The split gives each machine the job it can actually do: the VPS is the
public face, the workstation does the work.

---

## Architecture

```
GitHub org ── one org webhook ──► VPS
                                   │
                                   │  nginx :443  (certbot / Let's Encrypt)
                                   │  TLS terminated here
                                   ▼
                              n8n  (127.0.0.1:5678, no public port)
                                   │
                                   │  ONE SSH credential
                                   │  over Tailscale → 100.x.y.z:2200
                                   ▼
═══════════════════════════════════╪═══════════════════ machine boundary
                                   ▼
                            manager-agent          (workstation)
                                   │  reads /etc/onym/employees.json,
                                   │  picks employee, posts routing
                                   │  comment, SSHes onward via
                                   │  manager-fanout key
                                   ▼  employees-net
            ┌─────────────────────┬┴─────────────────────┬───── ...
            ▼                     ▼                      ▼
      dev-agent-agent       lead-agent-agent      ux-agent-agent
      (Debian arm64          (same image,         (same image,
       + Rust + Claude        ROLE=employee)       ROLE=employee)
       + gh, "@dev-agent")   "@lead-agent"        "@ux-agent"
            │                     │                      │
            │  optional: forced-command SSH to a Mac build host
            └─────────────────────┴────────┬─────────────┘
                                           ▼
                       /Users/stellar-builder/bin/host-build-dispatch
                           (Xcode + fastlane + Match + darwin-arm64 NDK)
```

**Key trust rules:**

- n8n knows about exactly one downstream SSH target (`manager-agent`)
  via one credential. n8n is *blind* to which employees exist —
  adding/removing an employee never touches n8n.
- The manager has a dedicated `manager-fanout` SSH keypair generated on
  first boot (separate from its own `id_ed25519`) used only to reach
  employees. Each employee's `authorized_keys` trusts the manager's
  fan-out pubkey and (optionally) one operator admin key
  (`ADMIN_SSH_PUBKEY`) for interactive debugging — nothing else.
- The manager's sshd is published on the workstation's **Tailscale IP
  only** (`MANAGER_SSH_BIND`), so only tailnet peers can even open a
  connection to it. It is never exposed to the local network or the
  internet.
- nginx is the only public ingress. n8n binds `127.0.0.1:5678` and is
  unreachable from off-box.
- n8n has no docker-socket mount — it talks to the manager over SSH
  only, so it has no root on either host.
- Match / Keychain signing lives **only** in the Mac login keychain.
  Containers never see signing creds.
- Public ports: on the VPS, 80/tcp + 443/tcp+udp (nginx). On the
  workstation, nothing public — only `100.x.y.z:2200` on the tailnet and
  per-employee loopback SSH ports (e.g. 2202/tcp) declared in
  `employees.json`.

---

## Authorization model

- **Org webhook**: `bin/gh-webhooks-sync.sh` installs one
  organization-level webhook on `N8N_ALLOWED_ORG`. Every event from every
  repo in the org fans out to n8n on a fixed set of `/webhook/<path>`
  endpoints — no per-repo wiring.
- **Org-membership gate**: every workflow that a human can trigger
  (mentions, comments, slash commands) checks the sender via
  `GET /orgs/<org>/members/<sender.login>` (204 = member, 404 = not)
  using the `manager GitHub` credential. The manager bot's PAT therefore
  needs `read:org` and must itself be a member of `<org>`.
- **Agent-targeted mentions only**: workflows 07–12 fire only when the
  inbound text `@`-mentions a login listed in `N8N_AGENT_LOGINS`
  (n8n.env). Mentioning a human teammate is ignored. **If this variable
  is unset those workflows silently never run.**
- **Hard allowlist for `/merge`**: workflow 06 gates on
  `MERGE_AUTHORIZED_LOGINS` because merging is destructive. Org
  membership alone is intentionally not enough for `/merge`.
- **Loop prevention**: every employee login + the manager login are
  derived from `employees.json` and rejected by the dispatcher's bot
  guard. There's no per-workflow bot list to keep in sync — the manager
  dispatcher reads `/etc/onym/employees.json` directly.

---

## Layout

```
onixx-n8n-github/
├── Dockerfile.base              # arm64 Debian + JDK 21 + Android SDK + Rust
├── Dockerfile.agent             # + sshd + Claude + gh + dispatcher + agent scripts
│
├── docker-compose.vps.yml       # VPS half:  n8n only, behind the host's nginx
├── docker-compose.mac.yml       # workstation half: manager-agent
├── nginx/n8n.conf.example       # nginx server block for the VPS
│
├── docker-compose.employees.yml # GENERATED by render-employees-compose.sh
├── employees.json               # source of truth: manager + N employees
├── employees.json.example
├── employees/<login>.env        # per-employee env (gitignored, seeded by renderer)
├── .env                         # compose vars — MANAGER_SSH_BIND (gitignored)
├── manager/
│   └── routing-prompt.tmpl      # tunable prompt mounted into manager-agent (envsubst)
├── manager.env.example          # → manager.env
├── n8n.env.example
├── gh-webhooks.env.example
├── .env.example                 # → .env: STACK_ROLE + COMPOSE_FILE per machine
├── bin/
│   ├── _stack.sh                # sourced by the others: loads .env, role guard
│   ├── up.sh                    # bring up THIS machine's half
│   ├── down.sh                  # stop it (--volumes to wipe)
│   ├── doctor.sh                # PASS/FAIL checklist, role-aware
│   ├── reset-employee.sh <login> | manager
│   ├── render-employees-compose.sh   # employees.json → docker-compose.employees.yml
│   ├── n8n-deploy.sh            # push manager credentials + workflows into n8n
│   ├── gh-webhooks-sync.sh      # install/update the org-level GitHub webhook
│   ├── n8n-manager-dispatch.sh  # baked into the agent image as `n8n-manager-dispatch`
│   ├── n8n-agent-prep.sh        # → `n8n-agent-prep`
│   ├── n8n-agent-issue.sh       # → `n8n-agent-issue`        (workflow 01 / 07)
│   ├── n8n-agent-address.sh     # → `n8n-agent-address`      (workflow 05)
│   ├── n8n-agent-review.sh      # → `n8n-agent-review`       (workflow 04)
│   ├── n8n-agent-reply.sh       # → `n8n-agent-reply`        (workflows 08-12)
│   ├── n8n-agent-build.sh       # → `n8n-agent-build`        (workflow 03)
│   ├── n8n-agent-merge.sh       # → `n8n-agent-merge`        (workflow 06)
│   ├── n8n-agent-release-bump.sh # → `n8n-agent-release-bump` (workflow 02)
│   ├── remote-xcodebuild.sh     # → `remote-xcodebuild`
│   └── remote-jnilibs.sh        # → `remote-jnilibs`
├── n8n/
│   ├── README.md                # workflow-by-workflow specs
│   ├── workflows/               # exported JSON, deployed by n8n-deploy.sh
│   └── secrets.example/         # template credentials (gitignored real copy)
└── host/                        # optional, Mac-side build delegation
    ├── host-build-dispatch.sh
    ├── stellar-builder-bootstrap.sh
    └── launchd/
        ├── com.onym.n8n.plist        # LaunchAgent — runs at user login
        └── onym-n8n-launchd.sh       # wrapper: waits for docker, runs up.sh
```

---

## How routing works

The manager dispatcher (`bin/n8n-manager-dispatch.sh`) is the brain:

1. **Bot-loop guard**: drops events whose `sender.login` is the manager
   or any employee login (derived from `employees.json`), or whose
   `sender.type === 'Bot'`.
2. **Routing decision**, in priority order:
   1. Body `@`-mentions a known employee → that employee.
   2. PR has `requested_reviewer.login` matching a known employee
      (workflow 04) → that employee.
   3. Issue's first assignee is a known employee → that employee.
   4. Surface is mechanical (`release-merge`, `pr-build`, `pr-merge`) →
      `defaults.implementer`.
   5. Surface is `pr-review-requested` and no explicit reviewer →
      `defaults.reviewer`.
   6. Otherwise → ask `claude --print` to pick the best employee given
      each one's `specialization` + `tags` + the request title/body.
      Claude returns `{employee, confidence, reason}`. If confidence <
      0.5, fall back to `defaults.implementer`.
3. **Routing comment**: post a brief "Routed to @<employee> (_reason_)"
   comment as the manager bot on the source surface (issue, PR, or
   discussion via GraphQL) — the audit trail.
4. **Dispatch**: SSH from manager → chosen employee using the
   `manager-fanout` key, run the appropriate `n8n-agent-*` script with
   the workflow-supplied args. The employee's stdout/stderr is streamed
   back unchanged so n8n's downstream nodes see the original output
   contract.

### employees.json rules that bite

- **The key under `employees` must be identical to that bot's GitHub
  login.** The dispatcher resolves mentions, assignees and review
  requests with `.employees | has($login)` — a key that differs from the
  GitHub login makes `@`-mention routing silently no-op. The key also
  drives docker naming: service `<key>-agent`, container
  `onym-<key>-agent`.
- **`defaults.reviewer` and `defaults.implementer` must name employees
  that exist.** Both are read verbatim with no existence check; a stale
  login makes the manager SSH to a container that isn't there.
- Every `githubLogin`, plus the manager's, must also appear in
  `N8N_AGENT_LOGINS` in `n8n.env`.

**Adding a new employee**: edit `employees.json`, re-render, restart. The
renderer seeds `employees/<login>.env`, the compose overlay gets the new
service, the manager picks it up on the next dispatch. No workflow
changes, no n8n credential changes — but do add the login to
`N8N_AGENT_LOGINS` and log Claude in on the new container.

---

## Prerequisites

- **Docker Compose v2** on both machines. The compose files deliberately use
  the short `env_file: [./file.env]` form so they also parse on versions
  older than 2.24 — the long `{path, required}` form fails there with
  `services.n8n.env_file.0 must be a string`. Keep it that way when editing.
- `jq`, `git`, `openssl`, `ssh-keygen` on both machines.
- The agent image is built `--platform=linux/arm64`. On an x86 host,
  drop the `platform:` / `platforms:` keys from `docker-compose.mac.yml`
  and the employees renderer first.
- A **Claude subscription**, and a browser to complete the OAuth login.
- A domain with an A record pointing at the VPS.
- Four-ish GitHub accounts: one per agent, plus the manager, all members
  of the org.

Budget roughly 8 GB of RAM per concurrently-working employee container on
the workstation, and ~10 GB of disk for the base image.

---

## Hybrid setup

### 0. GitHub accounts and tokens

One account per agent plus one for the manager, each a member of the org.
For each, log in as that bot and create a classic PAT at
`github.com/settings/tokens/new` with scopes `repo`, `read:org`,
`write:discussion`.

Fine-grained PATs also work but need the org to allow them, plus
Organization → Members → **Read**, without which the org-membership gate
fails.

Your own `gh` needs one extra scope to register the webhook:

```bash
gh auth refresh -h github.com -s admin:org_hook
```

| Secret | Goes in | Machine |
|---|---|---|
| manager PAT | `manager.env` → `GITHUB_TOKEN` | workstation |
| manager PAT (same value) | `n8n/secrets/github-manager-bot.json` → `data.accessToken` | VPS |
| each employee PAT | `employees/<login>.env` → `GITHUB_TOKEN` | workstation |
| your own GitHub login | `n8n.env` → `MERGE_AUTHORIZED_LOGINS`; `employees.json` → `defaults.humanQa`, `mergeAuthorizedLogins` | both |
| org name | `n8n.env` → `N8N_ALLOWED_ORG`; `gh-webhooks.env` → `GH_ORG` | both |

### 1. Tailscale

```bash
# workstation
brew install tailscale && sudo tailscale up
tailscale ip -4                 # → 100.x.y.z, note it down

# VPS
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ping 100.x.y.z        # must answer before continuing
```

### 2. Workstation — agents

```bash
git clone git@github.com:OnixxTeam/onixx-n8n-github.git
cd onixx-n8n-github

cp manager.env.example manager.env
cp employees.json.example employees.json
echo 'MANAGER_SSH_BIND=100.x.y.z' > .env      # this machine's Tailscale IP
chmod 600 manager.env employees.json
```

Generate the n8n → manager keypair, put the public half in `manager.env`:

```bash
mkdir -p n8n/secrets && chmod 700 n8n/secrets
ssh-keygen -t ed25519 -N "" -f n8n/secrets/n8n-manager-key -C "n8n@manager-agent"
# → paste n8n-manager-key.pub into N8N_SSH_PUBKEY in manager.env
```

Fill in `employees.json` (one block per employee, key = GitHub login) and
`manager.env` → `GITHUB_TOKEN`, then boot:

```bash
docker build --platform=linux/arm64 -f Dockerfile.base \
    -t onym-n8n/dev-env-base:latest .
./bin/render-employees-compose.sh
# fill in GITHUB_TOKEN in each seeded employees/<login>.env
./bin/up.sh
```

Grab the manager's fan-out pubkey, paste it into every
`employees/<login>.env` as `MANAGER_SSH_PUBKEY`, restart the employees:

```bash
docker logs onym-manager-agent | grep -A2 MANAGER_SSH_PUBKEY
docker compose restart $(jq -r '.employees | keys[] | "\(.)-agent"' employees.json | tr '\n' ' ')
```

(`docker compose` needs no `-f` flags anywhere: `COMPOSE_FILE` in `.env`
names the files, and compose reads it natively.)

Verify the manager can reach an employee:

```bash
docker exec -u agent onym-manager-agent \
    ssh -i ~/.ssh/manager-fanout -o StrictHostKeyChecking=no \
    agent@<login>-agent hostname
```

### 3. Claude Code — subscription login

There is no `ANTHROPIC_API_KEY` anywhere in this deployment. Instead, log
in interactively **once per container** — the manager included, since it
runs `claude --print` to route by specialization:

```bash
docker exec -it -u agent onym-manager-agent claude
# /login → follow the URL → paste the code back → /exit
```

Repeat for every `onym-<login>-agent`. The OAuth token lands in
`~/.claude/.credentials.json` inside the container's home volume and
survives restarts and image rebuilds. It does **not** survive
`bin/reset-employee.sh`, which wipes the volume.

If `ANTHROPIC_API_KEY` is ever set in the environment, Claude Code uses it
and ignores the subscription — keep it out of the env files.

### 4. VPS — n8n behind nginx

```bash
git clone git@github.com:OnixxTeam/onixx-n8n-github.git
cd onixx-n8n-github
cp n8n.env.example n8n.env && chmod 600 n8n.env
openssl rand -hex 32          # → N8N_ENCRYPTION_KEY
```

Fill in `n8n.env`: `N8N_ENCRYPTION_KEY`, `N8N_BASIC_AUTH_PASSWORD`,
`N8N_HOST`, `WEBHOOK_URL` (`https://<N8N_HOST>/`), `N8N_ALLOWED_ORG`,
`MERGE_AUTHORIZED_LOGINS`, `N8N_AGENT_LOGINS`.

Copy the credential files over from the workstation:

```bash
# from the workstation
scp -r n8n/secrets <vps>:~/onixx-n8n-github/n8n/
```

On the VPS, point the SSH credential at the workstation and fill in the
manager PAT:

```jsonc
// n8n/secrets/ssh-manager-agent.json
{ "data": { "host": "100.x.y.z", "port": 2200, "username": "agent", ... } }
// n8n/secrets/github-manager-bot.json
{ "data": { "accessToken": "ghp_…" } }
```

Bring up n8n and put nginx in front of it:

```bash
./bin/up.sh

cp nginx/n8n.conf.example /etc/nginx/sites-available/n8n.conf
# replace n8n.example.com with N8N_HOST
ln -s /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d <N8N_HOST>
```

`X-Forwarded-Proto` is not optional: n8n runs with `N8N_SECURE_COOKIE=true`
and `N8N_PROXY_HOPS=1`, so without that header it issues a Secure cookie
over what it believes is plain HTTP and the login page just reloads with
no error shown.

### 5. Wire the halves together

Check that the n8n container can actually open a socket to the
workstation across the tailnet:

```bash
docker exec onym-n8n node -e "require('net').connect(2200,'100.x.y.z')\
  .on('connect',()=>{console.log('OK');process.exit(0)})\
  .on('error',e=>{console.log('FAIL',e.message);process.exit(1)})"
```

`FAIL` usually means `MANAGER_SSH_BIND` is wrong — `docker port
onym-manager-agent` on the workstation should show `100.x.y.z:2200`.

Then create the n8n owner account at `https://<N8N_HOST>/` and push the
workflows:

```bash
./bin/n8n-deploy.sh            # on the VPS
```

### 6. Register the org webhook

From whichever machine has your personal `gh` authenticated:

```bash
cp gh-webhooks.env.example gh-webhooks.env   # GH_ORG + WEBHOOK_BASE_URL
./bin/gh-webhooks-sync.sh
```

### 7. Smoke test

Open an issue in any repo in the org and comment:

```
@dev-agent add a README describing this project
```

Expected chain: org webhook → n8n `/webhook/issue-mention` → SSH over
Tailscale into `manager-agent` → "Routed to @dev-agent" comment → SSH to
the employee → branch `agent/issue-<N>`, commit, PR → review auto-requested
from `defaults.reviewer`.

When nothing happens:

```bash
docker logs -f onym-n8n                             # VPS
docker logs -f onym-manager-agent                   # workstation
gh api orgs/<org>/hooks --jq '.[].last_response'
```

---

## Day-to-day commands

Every script reads `.env` and acts on whichever half this machine runs, so
the same commands work on both:

```bash
./bin/up.sh                         # build if needed + start this half
./bin/down.sh                       # stop it (volumes kept)
./bin/down.sh --volumes             # ... and wipe volumes (asks first)
./bin/doctor.sh                     # role-aware PASS/FAIL checklist

# workstation only
./bin/render-employees-compose.sh   # re-render after editing employees.json
./bin/reset-employee.sh <login>     # wipe one employee's volumes + rebuild
                                    # (also wipes its Claude login)

# VPS only
./bin/n8n-deploy.sh                 # (re)push workflows + credentials into n8n

# either machine, needs your personal gh
./bin/gh-webhooks-sync.sh           # (re)sync the org webhook

# Reach an employee SSH directly (only if sshHostPort is set in employees.json):
ssh -p 2202 agent@127.0.0.1
```

Running a script on the wrong machine is refused rather than half-executed:

```
ERROR n8n-deploy.sh only runs on the 'vps' half; this machine's .env says
      STACK_ROLE=workstation
```

`bin/establish.sh` — upstream's interactive setup wizard — was deleted. It
assumed a single host, rewrote every config file from its own answers, and
required a non-empty `ANTHROPIC_API_KEY`, which this deployment does not
use. Recover it from upstream if you ever want it:

```bash
git show upstream/main:bin/establish.sh
```

### Moving the agent half to another machine

Nothing in `bin/` hardcodes a compose filename — `COMPOSE_FILE` in `.env`
is the only place they are named. Migrating the agents from a Mac to a
Linux box is a rename plus one edited line:

```bash
git mv docker-compose.mac.yml docker-compose.linux.yml
# .env:  COMPOSE_FILE=docker-compose.linux.yml:docker-compose.employees.yml
```

Also drop the `platform: linux/arm64` / `platforms:` keys from that file and
from `bin/render-employees-compose.sh` if the new host is x86_64, and point
`ssh-manager-agent.json` on the VPS at the new machine's Tailscale IP.

Operator `~/.ssh/config` for direct admin SSH (the public half of this key
needs to be in `ADMIN_SSH_PUBKEY` in `manager.env` and in each
`employees/<login>.env`):

```
Host dev-agent
    HostName 127.0.0.1
    Port 2202
    User agent
    RequestTTY yes
    RemoteCommand tmux new-session -A -s dev-agent
```

(Add one block per employee whose `employees.json` entry has a
`sshHostPort`.)

---

## Running the workstation half at boot

macOS Docker (Docker Desktop / OrbStack) is a per-user GUI app — there is
no system-wide daemon a LaunchDaemon could drive. The standard pattern:

```
boot → macOS auto-logs into your user → Docker Desktop auto-starts
     → ~/Library/LaunchAgents/com.onym.n8n.plist fires
     → host/launchd/onym-n8n-launchd.sh waits for docker, runs the compose up
```

1. **Auto-login the user** (admin, one-time): System Settings → Users &
   Groups → Automatic login.
2. **Auto-start Docker**: Docker Desktop → Preferences → General → "Start
   Docker Desktop when you log in"; OrbStack → Settings → System → "Start
   at login".
3. **Prevent sleep**:
   ```bash
   pmset -a sleep 0 displaysleep 0 disksleep 0
   ```
4. **Install the LaunchAgent**:
   ```bash
   sed -i '' "s|/Users/REPLACE_ME|$HOME|g" host/launchd/com.onym.n8n.plist
   mkdir -p ~/logs ~/Library/LaunchAgents
   cp host/launchd/com.onym.n8n.plist ~/Library/LaunchAgents/
   launchctl load -w ~/Library/LaunchAgents/com.onym.n8n.plist
   ```

The wrapper calls `./bin/up.sh`, which now does the right thing for
whichever half `.env` declares — no edit needed. Failures land in
`~/logs/n8n.err.log`.

Also make sure Tailscale itself starts at login, or the VPS loses its
route to the manager after every reboot.

---

## What to never do

- **Do not** mount the host repo into the containers. Workspaces are
  cloned into named volumes per-employee.
- **Do not** put Match credentials or the Android keystore in any
  `.env` file. They live in the Mac login keychain / GitHub Actions
  secrets respectively.
- **Do not** mount `/var/run/docker.sock` into n8n. n8n talks to
  manager-agent over SSH only.
- **Do not** add employee logins to `MERGE_AUTHORIZED_LOGINS` — that
  defeats the human-gate on destructive merges.
- **Do not** edit `docker-compose.employees.yml` by hand — re-render
  via `./bin/render-employees-compose.sh`.
- **Do not** give any employee SSH access to another employee — the
  fan-out direction is one-way, manager → employees only.
- **Do not** bind `MANAGER_SSH_BIND` to `0.0.0.0`. Keep the manager's
  sshd on the Tailscale IP.
- **Do not** change `N8N_ENCRYPTION_KEY` after `n8n-deploy.sh` has run —
  every stored credential becomes undecryptable.
