#!/usr/bin/env bash
# Feishu bridge (server edition) health hook — HTTPS via CF Tunnel.
# Judges CONNECTION liveness from the daemon heartbeat's ws_state
# fields (written by bridge_daemon.py since 2026-11-25), not just
# process liveness: a daemon can be alive with a dead WS link.
# The server also has its own local watchdog + systemd, so this hook
# only wakes the agent when the bridge looks down across two polls.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

BRIDGE="<bridge-slug>"
BASE_URL="https://<hub-host>/$BRIDGE"
TOKEN_FILE="$HOME/hooks/state/feishu-hub/$BRIDGE.token"
STATE_DIR="$HOME/hooks/state/feishu-health-remote"
mkdir -p "$STATE_DIR"
FAIL_FILE="$STATE_DIR/fail_count"

[ -f "$TOKEN_FILE" ] || { silent "token_missing" '{}'; exit 0; }
TOKEN="$(cat "$TOKEN_FILE")"

hb="$(curl -s --max-time 12 -H "Authorization: Bearer $TOKEN" "$BASE_URL/heartbeat" || echo __FAIL__)"

fail=0
[ -f "$FAIL_FILE" ] && fail="$(cat "$FAIL_FILE")"

if [ "$hb" = "__FAIL__" ] || ! printf '%s' "$hb" | grep -q '"heartbeat"'; then
  fail=$((fail + 1))
  echo "$fail" > "$FAIL_FILE"
  log "hub_unreachable" "{\"count\":$fail}"
  if [ "$fail" -ge 3 ]; then
    echo 0 > "$FAIL_FILE"
    wake "feishu_hub_unreachable" "{\"consecutive_failures\":3}"
  else
    silent "hub_unreachable_pending" "{\"count\":$fail}"
  fi
  exit 0
fi

verdict="$(printf '%s' "$hb" | python3 -c '
import sys, json, time
d = json.load(sys.stdin)
h = d.get("heartbeat") or {}
now = int(time.time())
age = now - int(h.get("ts") or 0)
ws = h.get("ws_state")
last_conn = h.get("ws_last_connected_ts") or h.get("started_at") or now
gap = now - int(last_conn)
bad = 0
reason = "ok"
if age > 180:
    bad, reason = 1, "heartbeat_stale"
elif ws not in (None, "connected") and gap > 300:
    bad, reason = 1, "ws_down"
print(json.dumps({"bad": bad, "reason": reason, "heartbeat_age_seconds": age, "ws_state": ws, "ws_gap_seconds": gap}))
' 2>/dev/null || echo __PARSE_FAIL__)"

if [ "$verdict" = "__PARSE_FAIL__" ]; then
  silent "heartbeat_parse_failed" '{}'
  exit 0
fi

bad="$(printf '%s' "$verdict" | python3 -c 'import sys, json; print(json.load(sys.stdin)["bad"])')"

if [ "$bad" = "0" ]; then
  echo 0 > "$FAIL_FILE"
  silent "healthy" "$verdict"
  exit 0
fi

fail=$((fail + 1))
echo "$fail" > "$FAIL_FILE"
log "bridge_unhealthy" "$verdict"
if [ "$fail" -ge 2 ]; then
  echo 0 > "$FAIL_FILE"
  wake "feishu_bridge_unhealthy" "$verdict"
else
  silent "bridge_unhealthy_pending" "$verdict"
fi
