# onym-n8n

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

iOS builds and Android JNI builds are optionally delegated to a Mac mini
host via a single forced-command SSH dispatcher (skip the host pieces if
you only need pure-Linux flows).

---

## Authorization model

- **Org webhook**: `bin/gh-webhooks-sync.sh` installs one
  organization-level webhook on `N8N_ALLOWED_ORG` (default `onymchat`).
  Every event from every repo in the org fans out to n8n on a fixed set
  of `/webhook/<path>` endpoints — no per-repo wiring.
- **Org-membership gate**: every workflow that a human can trigger
  (mentions, comments, slash commands) checks the sender via
  `GET /orgs/<org>/members/<sender.login>` (204 = member, 404 = not)
  using the `manager GitHub` credential. The manager bot's PAT therefore
  needs `read:org` and must itself be a member of `<org>`.
- **Hard allowlist for `/merge`**: workflow 06 still gates on
  `MERGE_AUTHORIZED_LOGINS` (default `alexpovstin,gramyzer`) because
  merging is destructive. Org membership alone is intentionally not
  enough for `/merge`.
- **Loop prevention**: every employee login + the manager login are
  derived from `employees.json` and rejected by the dispatcher's bot
  guard. There's no per-workflow `N8N_BOT_LOGINS` to keep in sync — the
  manager dispatcher reads `/etc/onym/employees.json` directly.

---

## Architecture

```
GitHub org ── one org webhook ──► caddy :443  (Let's Encrypt cert)
                                       │ HTTPS terminated here
                                       │ orchestration net
                                       ▼
                                  n8n  (no public port; loopback :5678
                                   │   only for /healthz)
                                   │ ONE SSH credential
                                   ▼
                          manager-agent
                                   │  reads /etc/onym/employees.json,
                                   │  picks employee, posts routing
                                   │  comment, SSHes onward via
                                   │  manager-fanout key
                                   ▼  employees-net
            ┌─────────────────────┬┴─────────────────────┬───── ...
            ▼                     ▼                      ▼
     gramyzer-agent         onymyzer-agent        carol-agent
     (Debian arm64           (same image,         (same image,
      + Rust + Claude         ROLE=employee)       ROLE=employee)
      + gh, "@gramyzer")     "@onymyzer"          "@carol-bot"
            │                     │                      │
            │  optional: forced-command SSH back to mac-host
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
- Caddy is the only public ingress: TLS terminates there with a Let's
  Encrypt cert (ACME HTTP-01 on :80, HTTPS/HTTP-3 on :443).
- n8n has no docker-socket mount — it talks to the manager over SSH
  only, so it has no root on the host.
- Match / Keychain signing lives **only** in the Mac login keychain.
  Containers never see signing creds.
- Public ports on the host: 2222/tcp (sshd, operator admin access),
  80/tcp (Caddy ACME), 443/tcp+udp (Caddy HTTPS / HTTP/3), plus
  per-employee loopback SSH ports (e.g. 2201/tcp) declared in
  `employees.json`.

---

## Layout

```
onym-n8n/
├── Dockerfile.base              # arm64 Debian + JDK 21 + Android SDK + Rust
├── Dockerfile.agent             # + sshd + Claude + gh + dispatcher + agent scripts
├── Caddyfile                    # public ingress: TLS + reverse proxy → n8n
├── docker-compose.dev.yml       # base: caddy + n8n + manager-agent
├── docker-compose.employees.yml # GENERATED by render-employees-compose.sh
├── employees.json               # source of truth: manager + N employees
├── employees.json.example
├── employees/<login>.env        # per-employee env (gitignored, seeded by renderer)
├── manager/
│   └── routing-prompt.tmpl      # tunable prompt mounted into manager-agent (envsubst)
├── manager.env.example          # → manager.env, fill in manager bot's PAT etc.
├── n8n.env.example
├── caddy.env.example
├── gh-webhooks.env.example
├── bin/
│   ├── establish.sh             # interactive setup wizard (one-shot bootstrap)
│   ├── up.sh                    # render overlay + build + compose up
│   ├── down.sh
│   ├── doctor.sh                # PASS/FAIL checklist (per-employee aware)
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

**Adding a new employee**: edit `employees.json` (add a key under
`employees`), run `./bin/up.sh`. The renderer seeds
`employees/<login>.env`, the compose overlay gets the new service, the
manager picks it up on the next dispatch. No workflow changes, no n8n
credential changes.

---

## Quick start

### Recommended: interactive wizard

```bash
git clone git@github.com:onymchat/onym-n8n.git ~/Developer/onym-n8n
cd ~/Developer/onym-n8n
./bin/establish.sh
```

`bin/establish.sh` walks you through stack-wide config (public domain,
ACME email, GitHub org, n8n auth) → manager bot creds → each employee
(login, specialization, tags, PAT, Anthropic key) one by one. It then:

1. Generates the n8n→manager SSH keypair and embeds it in n8n's
   credential JSON.
2. Writes `caddy.env`, `n8n.env`, `gh-webhooks.env`, `manager.env`,
   `employees.json`, `employees/<login>.env`, and the two
   `n8n/secrets/*.json` credential files (existing files backed up
   to `.bak.<timestamp>/`).
3. Runs `./bin/up.sh` to render the compose overlay and boot the stack.
4. Polls `docker logs onym-manager-agent` until the manager prints its
   fan-out pubkey, then injects it into every `employees/<login>.env`
   and restarts those containers.

Single command, no manual file editing. After it finishes you still
need to: point DNS at the host, open 80/443 inbound, run
`./bin/n8n-deploy.sh` and `./bin/gh-webhooks-sync.sh` (it prints these
as next steps).

### Manual path (if you'd rather edit files by hand)

```bash
git clone git@github.com:onymchat/onym-n8n.git ~/Developer/onym-n8n
cd ~/Developer/onym-n8n

# 1. Env files (gitignored).
cp manager.env.example     manager.env
cp n8n.env.example         n8n.env
cp caddy.env.example       caddy.env
cp gh-webhooks.env.example gh-webhooks.env
cp employees.json.example  employees.json
chmod 600 manager.env n8n.env caddy.env gh-webhooks.env

# 2. Edit values. Fill in:
#    - manager.env:     GITHUB_TOKEN (manager bot PAT), ANTHROPIC_API_KEY
#    - n8n.env:         N8N_ENCRYPTION_KEY, N8N_BASIC_AUTH_PASSWORD,
#                       N8N_HOST + WEBHOOK_URL (must match caddy.env)
#    - caddy.env:       N8N_PUBLIC_HOST (your DNS), ACME_EMAIL
#    - gh-webhooks.env: GH_ORG, WEBHOOK_BASE_URL (= https://N8N_PUBLIC_HOST)
#    - employees.json:  one entry per employee bot account, with
#                       host (= "<login>-agent"), githubLogin,
#                       specialization, tags, and a sshHostPort if you
#                       want loopback SSH access from the host.

# 3. Build base image + bring up the stack. up.sh:
#    - renders docker-compose.employees.yml from employees.json,
#    - seeds employees/<login>.env templates,
#    - builds the agent image,
#    - compose up,
#    - prints each agent's id_ed25519 pubkey AND the manager's
#      MANAGER_SSH_PUBKEY.
docker build --platform=linux/arm64 -f Dockerfile.base \
    -t onym-n8n/dev-env-base:latest .
./bin/up.sh

# 4. Paste the printed MANAGER_SSH_PUBKEY into MANAGER_SSH_PUBKEY in
#    every employees/<login>.env, then restart the employees:
docker compose -f docker-compose.dev.yml -f docker-compose.employees.yml \
    restart $(jq -r '.employees | keys[] | "\(.)-agent"' employees.json | tr '\n' ' ')

# 5. Fill in real GITHUB_TOKEN + ANTHROPIC_API_KEY in each employee env
#    (the renderer seeded placeholder values), then restart that
#    employee. (Skip employees you haven't provisioned yet — they'll
#    just refuse to clone repos.)

# 6. n8n credentials + workflows.
cp -R n8n/secrets.example n8n/secrets
chmod 600 n8n/secrets/*.json
# Fill in: ssh-manager-agent.json, github-manager-bot.json
#          (see n8n/secrets.example/README.md)
./bin/n8n-deploy.sh

# 7. Org webhook.
./bin/gh-webhooks-sync.sh
```

Public DNS + first n8n login:

1. **DNS**: A/AAAA record for `N8N_PUBLIC_HOST` → host's public IP.
2. **Firewall**: 80/tcp + 443/tcp+udp inbound on the host.
3. **Watch Caddy issue the cert**:
   ```bash
   docker compose -f docker-compose.dev.yml logs -f caddy
   ```
4. **Create the n8n owner account** at `https://N8N_PUBLIC_HOST/`.
   `http://127.0.0.1:5678/` won't work for login (cookies are
   `Secure`-flagged) — that loopback port is bound only for
   `bin/doctor.sh`'s `/healthz` check.

---

## Day-to-day commands

```bash
./bin/up.sh                       # render overlay + build + compose up
./bin/down.sh
./bin/reset-employee.sh <login>   # wipe one employee's volumes + rebuild
./bin/reset-employee.sh manager   # same, for the manager
./bin/doctor.sh                   # structural + reachability checks
./bin/render-employees-compose.sh # re-render after editing employees.json
./bin/n8n-deploy.sh               # (re)push workflows + credentials into n8n
./bin/gh-webhooks-sync.sh         # (re)sync the org webhook

# Reach an employee SSH directly (only if sshHostPort is set in employees.json):
ssh -p 2201 agent@127.0.0.1   # gramyzer-agent in the example config
ssh -p 2202 agent@127.0.0.1   # onymyzer-agent in the example config
```

Operator `~/.ssh/config` for direct admin SSH (the public half of this
key needs to be in `ADMIN_SSH_PUBKEY` in `manager.env` and in each
`employees/<login>.env`):

```
Host onym-host
    HostName <public-dns-or-tailscale-name>
    Port 2222
    User stellar-builder

Host gramyzer-agent
    HostName 127.0.0.1
    Port 2201
    User agent
    ProxyJump onym-host
    RequestTTY yes
    RemoteCommand tmux new-session -A -s gramyzer

Host onymyzer-agent
    HostName 127.0.0.1
    Port 2202
    User agent
    ProxyJump onym-host
    RequestTTY yes
    RemoteCommand tmux new-session -A -s onymyzer
```

(Add one block per employee whose `employees.json` entry has a
`sshHostPort`.)

---

## Mac mini rollout

The Mac-host setup (Xcode + Match + sdkmanager + sshd hardening + the
forced-command dispatcher) is unchanged from the original — see the
`host/` README and `host/stellar-builder-bootstrap.sh`. The only delta
under the new model is:
- `qa.env` / `release.env` no longer exist — replace with `manager.env`
  and `employees/<login>.env` files (the renderer seeds them).
- The macOS firewall must additionally open 80/tcp + 443/tcp+udp for
  Caddy.
- `./bin/up.sh` does the compose-overlay rendering for you.

### Run on machine boot (no human login needed)

macOS Docker (Docker Desktop / OrbStack) is fundamentally a per-user
GUI app — there is no system-wide daemon you can drive from a
LaunchDaemon. The standard "Mac mini as a server" pattern is therefore:

```
boot → macOS auto-logs into your user → Docker Desktop auto-starts
     → ~/Library/LaunchAgents/com.onym.n8n.plist fires
     → host/launchd/onym-n8n-launchd.sh waits for docker, runs ./bin/up.sh
```

Effect: power on the Mac, the stack is up within 60-90s, no keyboard
ever touched. Setup steps (the auto-login one needs admin **once**;
everything else stays in your user account):

1. **Auto-login the user** (admin, one-time):
   System Settings → Users & Groups → Automatic login as "<your user>".
   You'll have to enter an admin password to confirm. After that the
   Mac boots straight to your desktop.

2. **Auto-start Docker** (no admin):
   - **Docker Desktop**: Preferences → General → "Start Docker Desktop
     when you log in"
   - **OrbStack**: Settings → System → "Start at login"

3. **Prevent sleep** (no admin, recommended for a server role):
   System Settings → Lock Screen → "Start Screen Saver when inactive"
   = Never; "Turn display off on power adapter when inactive" =
   Never. Or via CLI:
   ```bash
   pmset -a sleep 0 displaysleep 0 disksleep 0
   ```
   (`pmset -a` works without sudo for display + disk sleep on most
   macOS releases; the sleep flag may need `sudo pmset` on newer
   versions — use System Settings if it fails.)

4. **Install the LaunchAgent** (no admin):
   ```bash
   # Edit the three /Users/REPLACE_ME paths in the plist + the wrapper
   # to match your home directory.
   sed -i '' "s|/Users/REPLACE_ME|$HOME|g" \
       host/launchd/com.onym.n8n.plist
   mkdir -p ~/logs ~/Library/LaunchAgents
   cp host/launchd/com.onym.n8n.plist ~/Library/LaunchAgents/
   launchctl load -w ~/Library/LaunchAgents/com.onym.n8n.plist
   ```

5. **Verify** (next reboot):
   ```bash
   sudo shutdown -r now    # or just power-cycle
   # then ssh in once it's back:
   docker ps               # should list onym-caddy, onym-n8n, onym-manager-agent, onym-<login>-agent
   tail ~/logs/n8n.out.log # wrapper's progress: "docker ready after Nx5s" + up.sh output
   ```

To unload (e.g. while iterating) without rebooting:
```bash
launchctl unload ~/Library/LaunchAgents/com.onym.n8n.plist
# manual control via ./bin/up.sh / ./bin/down.sh from here
```

The wrapper `host/launchd/onym-n8n-launchd.sh` polls `docker info` for
up to 5 minutes before giving up — that's the cold-boot Docker-Desktop
warm-up window. If it ever exits non-zero, the failure is in
`~/logs/n8n.err.log`.

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
  via `./bin/render-employees-compose.sh` (`./bin/up.sh` does it).
- **Do not** give any employee SSH access to another employee — the
  fan-out direction is one-way, manager → employees only.
