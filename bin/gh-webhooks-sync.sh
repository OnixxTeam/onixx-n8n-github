#!/bin/bash
# Create or update GitHub webhooks so each workflow in n8n/workflows/
# receives the events it filters on. Default mode installs a single
# org-level webhook that fires for every repo in the org — agents can
# then be summoned from any repo without per-repo wiring. A per-repo
# fallback is provided for installs that only need to attach to one
# specific repo.
#
# Idempotent: matches by webhook URL suffix. Re-run after any path
# change or to flip events on/off.
#
# Runs on your dev machine (the one `gh auth login` is authenticated on),
# not on the Mac mini. Hits the GitHub REST API directly.
#
# Config:
#   Defaults are read from gh-webhooks.env (gitignored).
#   Copy gh-webhooks.env.example → gh-webhooks.env and fill it in.
#   Positional args override the env file.
#
# Usage:
#   ./gh-webhooks-sync.sh                                # org mode, env-driven
#   ./gh-webhooks-sync.sh org <org> <webhook-base-url>   # org mode, args
#   ./gh-webhooks-sync.sh repo <owner/repo> <base-url>   # per-repo fallback
#
# Requirements:
#   - gh CLI authed.
#     Org mode needs:  admin:org_hook
#     Repo mode needs: admin:repo_hook
#     Refresh with:
#       gh auth refresh -h github.com -s admin:org_hook
#       gh auth refresh -h github.com -s admin:repo_hook
set -euo pipefail

DEV_ENV_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_FILE="$DEV_ENV_DIR/gh-webhooks.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi

MODE="${1:-org}"
case "$MODE" in
    org|repo) (( $# )) && shift ;;
    *)
        # Back-compat: bare "<owner/repo> <base-url>" call still works.
        if [[ "$MODE" == */* ]]; then
            MODE="repo"
        else
            MODE="org"
        fi
        ;;
esac

if [ "$MODE" = "org" ]; then
    TARGET="${1:-${GH_ORG:-}}"
    BASE="${2:-${WEBHOOK_BASE_URL:-}}"
else
    TARGET="${1:-${GH_REPO:-}}"
    BASE="${2:-${WEBHOOK_BASE_URL:-}}"
fi

if [ -z "$TARGET" ] || [ -z "$BASE" ]; then
    cat >&2 <<EOF
ERROR: target ($([ "$MODE" = "org" ] && echo GH_ORG || echo GH_REPO)) and WEBHOOK_BASE_URL must be set.

Option A — create the env file (recommended):
  cp $DEV_ENV_DIR/gh-webhooks.env.example $ENV_FILE
  chmod 600 $ENV_FILE
  # then edit it with real values

Option B — pass as positional args:
  $0 org  <org>          <webhook-base-url>
  $0 repo <owner/repo>   <webhook-base-url>
EOF
    exit 2
fi

BASE="${BASE%/}"   # strip trailing slash

# Verify gh scope before bothering the user with failed API calls.
if [ "$MODE" = "org" ]; then
    REQUIRED_SCOPE="admin:org_hook"
    HOOKS_API="orgs/$TARGET/hooks"
else
    REQUIRED_SCOPE="admin:repo_hook"
    HOOKS_API="repos/$TARGET/hooks"
fi

if ! gh auth status 2>&1 | grep -q "$REQUIRED_SCOPE"; then
    cat >&2 <<EOF
ERROR: current gh token lacks '$REQUIRED_SCOPE' scope.

Refresh with:
  gh auth refresh -h github.com -s $REQUIRED_SCOPE
EOF
    exit 1
fi

# path → space-separated GitHub event names. Matches what each workflow's
# IF node filters on. Kept explicit so a workflow edit forces a review
# here; fewer surprises than autodetection.
declare -a DESIRED
DESIRED+=("qa-issue                   issues")
DESIRED+=("release-merge              pull_request")
DESIRED+=("pr-build-comment           issue_comment")
DESIRED+=("pr-review-request          pull_request")
DESIRED+=("pr-address-comment         issue_comment")
DESIRED+=("pr-address-review-comment  pull_request_review_comment")
DESIRED+=("pr-merge                   issue_comment")
DESIRED+=("issue-mention              issue_comment")
# Conversational @-mention surfaces (workflows 08-12). Each one runs claude
# in the repo workspace, posts the stdout as a reply via gh / GraphQL, and
# does NOT push code changes. Discussion events fire only for repository
# discussions — team/org-level discussions are not in this webhook space.
DESIRED+=("issue-body-mention         issues")
DESIRED+=("pr-body-mention            pull_request")
DESIRED+=("pr-review-mention          pull_request_review")
DESIRED+=("discussion-mention         discussion")
DESIRED+=("discussion-comment-mention discussion_comment")

echo "==> fetching existing webhooks ($MODE: $TARGET)"
gh api "$HOOKS_API" --paginate > /tmp/gh-hooks.json

for line in "${DESIRED[@]}"; do
    # shellcheck disable=SC2086
    set -- $line
    PATH_SEG="$1"; shift
    EVENTS=("$@")
    URL="$BASE/webhook/$PATH_SEG"

    EVENTS_JSON="$(printf '%s\n' "${EVENTS[@]}" | jq -Rs \
        'split("\n") | map(select(length > 0))')"

    # Match by /webhook/<path> suffix so changing the base URL still
    # finds the existing hook and updates it in place (rather than
    # leaking a new hook alongside a stale one).
    EXISTING_ID="$(jq -r --arg suffix "/webhook/$PATH_SEG" \
        '[.[] | select(.config.url | endswith($suffix)) | .id] | .[0] // empty' \
        /tmp/gh-hooks.json)"

    if [ -z "$EXISTING_ID" ]; then
        echo "==> creating   $PATH_SEG  →  $URL"
        BODY=$(jq -n --arg url "$URL" --argjson events "$EVENTS_JSON" '{
            name: "web",
            active: true,
            events: $events,
            config: {
                url: $url,
                content_type: "json",
                insecure_ssl: "0"
            }
        }')
        NEW_ID="$(gh api -X POST "$HOOKS_API" \
            --input - <<<"$BODY" --jq '.id')"
        echo "    id=$NEW_ID events=${EVENTS[*]}"
        continue
    fi

    CURRENT_URL="$(jq -r --argjson id "$EXISTING_ID" \
        '.[] | select(.id == $id) | .config.url' /tmp/gh-hooks.json)"
    CURRENT_EVENTS="$(jq -r --argjson id "$EXISTING_ID" \
        '.[] | select(.id == $id) | .events | sort | join(",")' \
        /tmp/gh-hooks.json)"
    WANT_EVENTS="$(printf '%s\n' "${EVENTS[@]}" | sort | paste -sd, -)"

    if [ "$CURRENT_URL" = "$URL" ] && [ "$CURRENT_EVENTS" = "$WANT_EVENTS" ]; then
        echo "==> up-to-date $PATH_SEG  (id=$EXISTING_ID)"
        continue
    fi

    CHANGES=()
    [ "$CURRENT_URL" != "$URL" ] && CHANGES+=("url: $CURRENT_URL → $URL")
    [ "$CURRENT_EVENTS" != "$WANT_EVENTS" ] && \
        CHANGES+=("events: $CURRENT_EVENTS → $WANT_EVENTS")
    echo "==> updating   $PATH_SEG  (id=$EXISTING_ID)"
    for c in "${CHANGES[@]}"; do echo "    $c"; done

    BODY=$(jq -n --arg url "$URL" --argjson events "$EVENTS_JSON" '{
        active: true,
        events: $events,
        config: {
            url: $url,
            content_type: "json",
            insecure_ssl: "0"
        }
    }')
    gh api -X PATCH "$HOOKS_API/$EXISTING_ID" \
        --input - <<<"$BODY" >/dev/null
done

# Surface strays: hooks pointing at the same base URL but not in our
# desired list. Common causes: renamed a workflow path, or left a hook
# from a prior manual setup.
echo
echo "==> stray hooks under $BASE (not in desired set)"
DESIRED_URLS_JSON=$(printf '%s\n' "${DESIRED[@]}" | awk '{print "'"$BASE"'/webhook/"$1}' \
    | jq -Rs 'split("\n") | map(select(length > 0))')
STRAYS=$(jq -r --argjson want "$DESIRED_URLS_JSON" --arg base "$BASE" '
    .[] | select(.config.url | startswith($base))
        | select([.config.url] | inside($want) | not)
        | "  id=\(.id) url=\(.config.url) events=\(.events | join(","))"
' /tmp/gh-hooks.json)
if [ -n "$STRAYS" ]; then
    echo "$STRAYS"
    echo
    echo "  delete with:  gh api -X DELETE $HOOKS_API/<id>"
else
    echo "  (none)"
fi

rm -f /tmp/gh-hooks.json
echo
echo "done. ${#DESIRED[@]} webhooks synced ($MODE: $TARGET)."
