#!/usr/bin/env bash
# Bump the version + push a tag after a PR merges into main. Invoked by
# the manager dispatcher (workflow 02 → manager-agent → SSH → here).
#
# Relies on the repo's `scripts/sync-versions.sh` to update version files
# in lockstep — that's a per-repo contract, not enforced here. If the
# repo doesn't ship that script, this run no-ops gracefully and just
# pushes the tag.
#
# Args:
#   $1 = bump kind (major|minor|patch, default patch)
#
# Output contract:
#   NEW_TAG=<vX.Y.Z>
#   PUSH_RC=<int>
set +e
set -o pipefail

BUMP="${1:-patch}"
case "$BUMP" in major|minor|patch) ;; *) BUMP=patch ;; esac

git fetch origin main 2>&1 || { echo "ERROR: fetch main failed" >&2; exit 11; }
git checkout main 2>&1
git pull --ff-only origin main 2>&1 || { echo "ERROR: ff-pull failed" >&2; exit 12; }

LAST=$(git tag --list 'v*' --sort=-v:refname | head -1)
LAST="${LAST:-v0.0.0}"
IFS=. read -r MA MI PA <<<"${LAST#v}"
case "$BUMP" in
  major) NEW="$((MA+1)).0.0" ;;
  minor) NEW="${MA}.$((MI+1)).0" ;;
  patch) NEW="${MA}.${MI}.$((PA+1))" ;;
esac

if [ -x ./scripts/sync-versions.sh ]; then
  ./scripts/sync-versions.sh "$NEW" || echo "WARN: sync-versions.sh failed, continuing with tag-only" >&2
  if ! git diff --quiet; then
    git commit -am "release: v${NEW}" 2>&1 || true
  fi
fi

git tag "v${NEW}" 2>&1
git push origin main --tags 2>&1
PUSH_RC=$?

echo "NEW_TAG=v${NEW}"
echo "PUSH_RC=$PUSH_RC"
exit 0
