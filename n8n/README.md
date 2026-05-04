# n8n workflows for the manager-mediated agent fleet

n8n runs in its own container (`onym-n8n`) on the `orchestration` docker
network alongside `caddy` and `manager-agent`. It reaches `manager-agent`
over SSH at `manager-agent:22` using one credential — `manager-agent SSH`.
Employees are *invisible* to n8n; the manager dispatcher inside
`manager-agent` reads `employees.json` and fans out internally.

---

## What the workflows do

All twelve workflows share the same minimal shape:

```
Webhook
  → IF (action filter — sender not Bot, action ∈ allowed set, etc.)
  → HTTP GET /orgs/<org>/members/<sender.login>     (when human-triggered)
  → IF statusCode == 204                            (org-membership gate)
  → Code: build args JSON + base64-encoded prompt
  → SSH manager-agent: exec n8n-manager-dispatch <argsB64>
```

The Code node emits a single `argsB64` field — base64 of a JSON object
with `surface`, `repoOwner`, `repoName`, `senderLogin`, the
surface-specific payload extract, and a `promptB64` (the prompt the
chosen employee will run). The dispatcher decodes everything, picks an
employee, posts a "Routed to @<employee>" comment as the manager bot,
and SSHes onward.

This shape is uniform across all 12 workflows — there are no per-host
`Switch` nodes and no per-employee SSH credentials. Adding an employee
never touches n8n.

---

## Required credentials (only two!)

```bash
cp -R n8n/secrets.example n8n/secrets
chmod 600 n8n/secrets/*.json
```

| File | n8n credential name | Used by |
|---|---|---|
| `ssh-manager-agent.json` | `manager-agent SSH` | every workflow's single SSH node |
| `github-manager-bot.json` | `manager GitHub` | org-membership HTTP gate + the dispatcher's routing-comment poster |

Full schema and provisioning playbook: `n8n/secrets.example/README.md`.

---

## Routing config — `employees.json`

The dispatcher reads `/etc/onym/employees.json` (mounted from the
project root by the compose stack). Schema:

```json
{
  "manager": {
    "host": "manager-agent",
    "port": 22,
    "user": "agent",
    "githubLogin": "onym-manager"
  },
  "employees": {
    "<login>": {
      "host": "<login>-agent",
      "port": 22,
      "user": "agent",
      "sshHostPort": 2201,
      "githubLogin": "<login>",
      "specialization": "<free text describing what they're best at>",
      "tags": ["rust", "ios", ...]
    }
  },
  "defaults": {
    "implementer": "<login>",
    "reviewer": "<login>",
    "humanQa": "<github-login>"
  },
  "mergeAuthorizedLogins": ["<github-login>", ...]
}
```

**Routing precedence** (manager dispatcher):
1. Body `@`-mentions a known employee → that employee.
2. PR `requested_reviewer` matches a known employee → that employee.
3. Issue's first assignee matches a known employee → that employee.
4. Mechanical surface (`release-merge`, `pr-build`, `pr-merge`) →
   `defaults.implementer`.
5. `pr-review-requested` with no explicit reviewer →
   `defaults.reviewer`.
6. Otherwise → ask `claude --print` to pick by inspecting each
   employee's `specialization` + `tags`. If confidence < 0.5, fall
   back to `defaults.implementer`.

**Adding an employee**: add a key under `employees` in `employees.json`,
run `./bin/up.sh`. The renderer regenerates the compose overlay and
seeds `employees/<login>.env`. No workflow changes, no n8n credential
changes.

**Tuning the routing prompt**: `manager/routing-prompt.tmpl` is mounted
read-only into `manager-agent` at `/etc/onym/routing-prompt.tmpl`. The
dispatcher `envsubst`-renders it with these variables:

| Variable | Source |
|---|---|
| `${EMP_BLOCK}` | one line per employee, formatted as `- @<login>: specialization=… \| tags=…` |
| `${SURFACE}` | the dispatch surface (e.g. `issue-action`, `pr-review`) |
| `${REPO_FULL}` | `<owner>/<repo>` |
| `${SENDER_LOGIN}` | the GitHub user who triggered the event |
| `${TITLE}` | issue / PR / discussion title |
| `${BODY}` | request body (truncated to 4000 chars) |
| `${DEFAULT_IMPL}` | `defaults.implementer` from `employees.json` |

Edit the file on the host and the next dispatch picks up the change —
no rebuild, no restart. If the file is unreadable for any reason the
dispatcher falls back to an embedded copy of the same prompt so the
fleet keeps working.

---

## Loop prevention

The dispatcher rejects events at step 1 if any of:

- `sender.type === 'Bot'`
- `sender.login` is the manager bot or any employee bot (derived from
  `employees.json`)
- `sender.login == 'github-actions[bot]'`

The workflow's `IF` filter also rejects bot senders before the SSH ever
fires, but the dispatcher's check is the authoritative one — it sees
*all* event metadata in the args JSON, so even unusual bot patterns get
caught.

---

## Workflow catalog

Filter expressions are abbreviated; see each `n8n/workflows/<file>.json`
for the full predicate.

### Action workflows (employee modifies code)

| # | File | Trigger event | Surface | Downstream script |
|---|---|---|---|---|
| 01 | `01-issue-action.json` | `issues` opened/reopened/labeled/assigned with assignee or `agent-task` label | `issue-action` | `n8n-agent-issue` |
| 02 | `02-release-merge.json` | `pull_request closed && merged` into main | `release-merge` | `n8n-agent-release-bump` |
| 03 | `03-pr-build-comment.json` | `issue_comment` matching `^/build (ios\|android)$` on a PR | `pr-build` | `n8n-agent-build` |
| 04 | `04-pr-review-request.json` | `pull_request review_requested` | `pr-review-requested` | `n8n-agent-review` |
| 05 | `05-pr-address-comment.json` | `issue_comment` (PR thread) or `pull_request_review_comment` with @-mention or `/fix` | `pr-address` | `n8n-agent-address` |
| 06 | `06-pr-merge-command.json` | `issue_comment` matching `^/merge` on PR + sender ∈ `MERGE_AUTHORIZED_LOGINS` | `pr-merge` | `n8n-agent-merge` |
| 07 | `07-issue-mention.json` | `issue_comment` on plain issue with @-mention | `issue-action` | `n8n-agent-issue` |

### Conversational workflows (employee just replies)

| # | File | Trigger event | Surface | Downstream script |
|---|---|---|---|---|
| 08 | `08-issue-body-mention.json` | `issues opened/edited` with @-mention in body (and, on edit, the mention is *new*) | `issue-body` | `n8n-agent-reply issue` |
| 09 | `09-pr-body-mention.json` | `pull_request opened/edited` with @-mention in body | `pr-body` | `n8n-agent-reply pr` |
| 10 | `10-pr-review-mention.json` | `pull_request_review submitted` with @-mention in review body | `pr-review` | `n8n-agent-reply pr` |
| 11 | `11-discussion-mention.json` | `discussion created/edited` with @-mention in body | `discussion` | `n8n-agent-reply discussion` |
| 12 | `12-discussion-comment-mention.json` | `discussion_comment created` with @-mention | `discussion-comment` | `n8n-agent-reply discussion-reply` |

The conversational ones discard any code changes Claude produces — for
code work, use the action workflows.

---

## Webhook event subscriptions

`bin/gh-webhooks-sync.sh` installs one webhook per workflow path on the
org-level webhook (or per-repo as fallback). Required event types:

```
issues, pull_request, pull_request_review, pull_request_review_comment,
issue_comment, discussion, discussion_comment
```

The `discussion` and `discussion_comment` events fire only for
**repository discussions** — team / org-level discussions are not in
this webhook space.

---

## Public ingress (Caddy)

Caddy terminates TLS at `https://$N8N_PUBLIC_HOST/` (set in
`caddy.env`) using a Let's Encrypt cert provisioned via ACME HTTP-01 on
:80. It then reverse-proxies to `n8n:5678` over the orchestration
network — n8n itself never publishes a public port.

You provide:
- DNS A/AAAA for `$N8N_PUBLIC_HOST` → host's public IP.
- Inbound 80/tcp + 443/tcp+udp open at the host firewall.
- `N8N_HOST` in `n8n.env` and the host portion of `WEBHOOK_URL` set to
  the same value as `N8N_PUBLIC_HOST`.

The webhook sync script registers the org-level GitHub webhook to POST
straight to `https://$N8N_PUBLIC_HOST/webhook/<path>` for each
workflow — no fan-out routing needed.

---

## Manual fallback (UI)

Use this only when `n8n-deploy.sh` can't run:

1. Open `https://$N8N_PUBLIC_HOST/` and create the owner account.
2. **SSH credential**: create `manager-agent SSH` (`sshPrivateKey` type)
   with host `manager-agent`, port 22, user `agent`, and the OpenSSH
   private key whose pubkey is in `manager.env` as `N8N_SSH_PUBKEY`.
3. **GitHub credential**: create `manager GitHub` (`githubApi` type)
   with the manager bot's PAT.
4. **Import workflows**: for each JSON under `workflows/`, click Import.
   Open the SSH node + every `httpRequest` GitHub node and re-bind the
   credential by name. Activate.

---

## Syncing workflow edits back to JSON

```bash
docker exec onym-n8n n8n export:workflow --id=<id> --output=/tmp/wf.json
docker cp onym-n8n:/tmp/wf.json n8n/workflows/<file>.json
```

Before committing, replace every concrete credential `id` with
`REPLACE_ME` (keep the `name`) so the file stays portable across fresh
n8n installs. The deploy script's credential-rewrite pass re-injects the
right ID on each import.

The compose stack also mounts `./n8n/workflows` read-only into the n8n
container at `/workflows` — convenient for hand-importing in the UI
during debugging, but not used by the deploy script.
