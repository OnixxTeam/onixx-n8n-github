#!/usr/bin/env bash
# Honor a /merge slash on a PR. Invoked by the manager dispatcher
# (workflow 06 → manager-agent → SSH → here). The dispatcher has already
# enforced N8N_MERGE_AUTHORIZED_LOGINS upstream.
#
# Args:
#   $1 = PR number
#   $2 = method (squash|rebase|merge)
#   $3 = PR title (used in smoke-test issue)
#   $4 = human QA login (assignee for smoke-test issue)
#
# Output contract:
#   MERGE_RC=<int>
#   SMOKE_RC=<int>
#   SMOKE_URL=<url or empty>
set +e
set -o pipefail

PR="${1:-}"
METHOD="${2:-squash}"
PR_TITLE="${3:-}"
QA_LOGIN="${4:-}"

if [ -z "$PR" ]; then
  echo "ERROR: usage: n8n-agent-merge <pr> <method> <pr-title> <qa-login>" >&2
  echo "MERGE_RC=2"
  exit 2
fi

case "$METHOD" in squash|rebase|merge) ;; *) METHOD=squash ;; esac

# Derive --repo from the workspace remote so we don't depend on cwd-PR
# coupling.
REPO=$(git config --get remote.origin.url \
        | sed -E 's|.*github.com[:/]([^/]+/[^.]+)(\.git)?|\1|')

gh pr merge "$PR" --"$METHOD" --delete-branch --repo "$REPO" 2>&1
MERGE_RC=$?
echo "MERGE_RC=$MERGE_RC"
if [ "$MERGE_RC" -ne 0 ]; then
  exit 0
fi

# Smoke-test issue, only on successful merge.
SMOKE_BODY="/tmp/smoke-$PR.md"
cat > "$SMOKE_BODY" <<MSG
Manually exercise the change from PR #$PR ("$PR_TITLE") on a real device
or staging environment. Close this issue when satisfied.
MSG

if [ -n "$QA_LOGIN" ]; then
  GH_OUT=$(gh issue create --repo "$REPO" \
            --title "Smoke test: $PR_TITLE" \
            --assignee "$QA_LOGIN" \
            --label smoke-test \
            --body-file "$SMOKE_BODY" 2>&1)
else
  GH_OUT=$(gh issue create --repo "$REPO" \
            --title "Smoke test: $PR_TITLE" \
            --label smoke-test \
            --body-file "$SMOKE_BODY" 2>&1)
fi
SMOKE_RC=$?
SMOKE_URL=$(printf '%s\n' "$GH_OUT" | grep -Eo 'https://github.com/[^ ]+/issues/[0-9]+' | tail -1)
rm -f "$SMOKE_BODY"
echo "SMOKE_RC=$SMOKE_RC"
echo "SMOKE_URL=$SMOKE_URL"
exit 0
