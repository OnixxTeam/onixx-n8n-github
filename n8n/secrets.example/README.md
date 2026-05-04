# n8n credentials — operator secrets

`./bin/n8n-deploy.sh` imports every JSON file in `../secrets/` (sibling
of this dir, gitignored) as an n8n credential. This folder holds the
templates — copy and fill in real values:

```bash
cp -R n8n/secrets.example n8n/secrets
chmod 600 n8n/secrets/*.json
# then edit each file with real keys / tokens
```

## Required credentials

In the manager-mediated model, n8n needs only **two** credentials —
regardless of how many employees you add. The manager fans out
internally over its own SSH key (`manager-fanout`); n8n never knows
about employees.

| File | n8n credential name | Used by |
|---|---|---|
| `ssh-manager-agent.json` | `manager-agent SSH` | every workflow's single SSH node |
| `github-manager-bot.json` | `manager GitHub` | org-membership HTTP check + (optionally) workflow-side GitHub nodes |

Drop additional JSON files into `secrets/` to import extra credentials —
they just won't be referenced by the shipped workflows.

## Field guide

### SSH credential (`sshPrivateKey` type)

- **host** — `manager-agent` (the container hostname on the
  `orchestration` Docker network).
- **port** — `22`.
- **username** — `agent`.
- **privateKey** — OpenSSH-format private key whose public half lives
  in `manager.env` as `N8N_SSH_PUBKEY`. Generate once:

  ```bash
  ssh-keygen -t ed25519 -f n8n/secrets/n8n-manager-key -N ""

  # Paste the pubkey into manager.env:
  pub=$(cat n8n/secrets/n8n-manager-key.pub)
  # → set N8N_SSH_PUBKEY="$pub" in manager.env, restart manager-agent.

  # Embed the private key into the credential JSON:
  priv=$(cat n8n/secrets/n8n-manager-key \
           | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
  # → paste into the "privateKey" field of ssh-manager-agent.json.
  ```

  The public half lands in `authorized_keys` on first-run of the manager
  (see `entrypoint/first-run.sh`).
- **passphrase** — empty unless you passed `-N` to `ssh-keygen`.

### GitHub credential (`githubApi` type — bearer token)

- **server** — `https://api.github.com` for public GitHub.
- **user** — cosmetic label shown in the n8n UI. Set to the manager
  bot's GitHub login (e.g. `onym-manager`).
- **accessToken** — bearer token the `n8n-nodes-base.github` node sends
  as `Authorization: Bearer <token>`. Two options:

  1. **Fine-grained PAT** (simplest): create at
     https://github.com/settings/personal-access-tokens/new, scope to
     the org's repos, grant the permissions below.
  2. **GitHub App installation token** (rotates hourly, more involved):
     generate from the App's private key via
     `/app/installations/{installation_id}/access_tokens` and paste.
     Re-run `n8n-deploy.sh` when the token rotates.

#### Permissions for the manager GitHub credential

The same token is used by:
- The workflow-side org-membership HTTP gate (just `read:org`).
- The dispatcher's "routed to @<employee>" comment poster, which posts
  on issues / PRs / discussions across every repo:

| Surface | Permission |
|---|---|
| Org membership lookup | `read:org` |
| Issue + PR comments | `issues:write`, `pull_requests:write` |
| Discussion comments | `read:discussion`, `write:discussion` (fine-grained: enable "Discussions" repository perm with read+write) |
| Read repo contents (workspace clones) | `contents:read`, `metadata:read` |

The **employees** each have their own PAT in
`employees/<login>.env` (`GITHUB_TOKEN`) — those are NOT n8n
credentials, they're container env that the employee's `gh` CLI
authenticates with.

## Rotation

```bash
vim n8n/secrets/github-manager-bot.json
./bin/n8n-deploy.sh
```

The script upserts by credential name, so IDs stay stable and no
workflow needs re-binding.
