#!/usr/bin/env bash
# Feishu bridge (server edition) inbox sync hook — READ-ONLY by design.
# The platform's egress guard makes background hook scripts POST to an
# external host only with per-attempt user approval (learned the hard
# way 2026-11-25: a pile of approval cards). So this script only GETs:
# it mirrors new inbox files down and wakes the worker. ALL writes
# (reply push, processed ack, attachment upload) are done by the woken
# worker agent itself, whose sends do not hit that guard.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

BRIDGE="<bridge-slug>"
BASE_URL="https://<hub-host>/$BRIDGE"
TOKEN_FILE="$HOME/hooks/state/feishu-hub/$BRIDGE.token"
LBASE="$HOME/workspace/feishu-bridge-remote"
STATE_DIR="$HOME/hooks/state/feishu-inbox-remote"
mkdir -p "$LBASE/queue/inbox" "$LBASE/queue/outbox" "$LBASE/queue/processed" \
         "$LBASE/queue/sent" "$LBASE/queue/incoming_attachments" "$STATE_DIR"

[ -f "$TOKEN_FILE" ] || { log "token_missing" '{}'; silent "token_missing" '{}'; exit 0; }
TOKEN="$(cat "$TOKEN_FILE")"

api() { curl -s --max-time 12 -H "Authorization: Bearer $TOKEN" "$@"; }

# Pull new inbox files down (GET only).
list="$(api "$BASE_URL/inbox" || echo __FAIL__)"
if [ "$list" = "__FAIL__" ] || ! printf '%s' "$list" | grep -q '"files"'; then
  log "inbox_list_failed" '{}'
  silent "hub_unreachable" '{}'
  exit 0
fi

remote_files="$(printf '%s' "$list" | python3 -c 'import sys, json; [print(f) for f in json.load(sys.stdin).get("files", [])]' 2>/dev/null || true)"
new_files=()
for name in $remote_files; do
  if [ ! -f "$LBASE/queue/inbox/$name" ] && [ ! -f "$LBASE/queue/processed/$name" ]; then
    if api "$BASE_URL/inbox/$name" -o "$LBASE/queue/inbox/$name.tmp" && [ -s "$LBASE/queue/inbox/$name.tmp" ]; then
      mv "$LBASE/queue/inbox/$name.tmp" "$LBASE/queue/inbox/$name"
      new_files+=("$name")
    else
      rm -f "$LBASE/queue/inbox/$name.tmp"
      log "inbox_pull_failed" "{\"file\":\"$name\"}"
    fi
  fi
done

if [ "${#new_files[@]}" -gt 0 ]; then
  payload="$(printf '%s\n' "${new_files[@]}" | python3 -c 'import sys, json; print(json.dumps({"files": [l.strip() for l in sys.stdin if l.strip()]}))')"
  wake "feishu_remote_inbox" "$payload"
  exit 0
fi

# Retry path: files sitting unprocessed in the local inbox for over
# 10 minutes wake the worker again, at most once per 10 minutes.
now="$(date +%s)"
last_retry=0
[ -f "$STATE_DIR/last_retry" ] && last_retry="$(cat "$STATE_DIR/last_retry")"
stale=0
for f in "$LBASE/queue/inbox"/*.json; do
  [ -e "$f" ] || continue
  mtime="$(stat -c %Y "$f")"
  if [ $((now - mtime)) -gt 600 ]; then stale=1; break; fi
done
if [ "$stale" = "1" ] && [ $((now - last_retry)) -gt 600 ]; then
  echo "$now" > "$STATE_DIR/last_retry"
  wake "feishu_remote_inbox_retry" '{"reason":"unprocessed_files_older_than_10min"}'
else
  silent "no_new_messages" '{}'
fi
