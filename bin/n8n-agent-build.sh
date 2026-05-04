#!/usr/bin/env bash
# Run a /build slash for a PR. Invoked by the manager dispatcher
# (workflow 03 → manager-agent → SSH → here).
#
# Args:
#   $1 = PR number
#   $2 = build target (ios|android)
#   $3 = head SHA
#
# Output contract:
#   BUILD_RC=<int>
#   BUILD_LOG_TAIL<<__END__ ... __END__
set +e
set -o pipefail

PR="${1:-}"
TARGET="${2:-}"
SHA="${3:-}"

if [ -z "$PR" ] || [ -z "$TARGET" ] || [ -z "$SHA" ]; then
  echo "ERROR: usage: n8n-agent-build <pr> <target> <sha>" >&2
  echo "BUILD_RC=2"
  exit 2
fi

LOG="/tmp/build-$PR-$TARGET.log"
trap 'rm -f "$LOG"' EXIT

case "$TARGET" in
  ios)
    /usr/local/bin/remote-xcodebuild "$SHA" > "$LOG" 2>&1
    ;;
  android)
    /usr/local/bin/remote-jnilibs "$SHA" > "$LOG" 2>&1 \
      && git checkout "$SHA" -- . >> "$LOG" 2>&1 \
      && ./gradlew :app:assembleRelease >> "$LOG" 2>&1
    ;;
  *)
    echo "ERROR: unknown build target '$TARGET' (expected ios|android)" >&2
    echo "BUILD_RC=3"
    exit 3
    ;;
esac

RC=$?
echo "BUILD_RC=$RC"
echo "BUILD_LOG_TAIL<<__END__"
tail -n 80 "$LOG" 2>/dev/null || true
echo "__END__"
exit "$RC"
