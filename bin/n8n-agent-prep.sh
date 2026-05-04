#!/usr/bin/env bash
# Prepare a per-repo workspace for an n8n round-trip. Clones the repo on
# demand into ~/workspaces/<owner>__<name>/, refreshes the remote URL
# with the bot token, and prints `eval`-ready exports so the calling SSH
# command inherits GH_TOKEN and the cwd. Usage:
#
#   eval "$(n8n-agent-prep <owner/repo>)" || exit $?
#
# Side effects (on stderr): clone progress / error messages.
# Stdout: shell statements only — newline-separated `export` and `cd`.
#
# Why this layer exists: agents in the dev-env stack are reachable from a
# single n8n container that drives multiple repos in the org. The legacy
# pinned-workspace path (~/workspace cloned from $GITHUB_REPO at first
# boot) is preserved for back-compat, but new flows route through here so
# any repo in the org can be addressed by webhook payload.
set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
    echo 'echo "ERROR: n8n-agent-prep requires <owner/repo>" >&2; exit 2'
    exit 0
fi
case "$REPO" in
    */*) ;;
    *)
        echo 'echo "ERROR: n8n-agent-prep arg must be <owner/repo>" >&2; exit 2'
        exit 0
        ;;
esac

TOKEN_FILE="$HOME/.gh-token"
if [ ! -r "$TOKEN_FILE" ]; then
    echo "echo 'ERROR: $TOKEN_FILE missing — first-run.sh did not persist GITHUB_TOKEN' >&2; exit 10"
    exit 0
fi
TOKEN=$(cat "$TOKEN_FILE")

WS="$HOME/workspaces/${REPO//\//__}"

if [ ! -d "$WS/.git" ]; then
    mkdir -p "$(dirname "$WS")"
    if ! git clone --quiet \
            "https://x-access-token:${TOKEN}@github.com/${REPO}.git" \
            "$WS" >&2; then
        echo "echo 'ERROR: clone failed for ${REPO}' >&2; exit 11"
        exit 0
    fi
fi

# Always refresh the remote URL — the token may have rotated.
git -C "$WS" remote set-url origin \
    "https://x-access-token:${TOKEN}@github.com/${REPO}.git" >&2 || true

printf 'export GH_TOKEN=%q\n' "$TOKEN"
printf 'cd %q\n' "$WS"
