#!/usr/bin/env bash
# Server-local watchdog for the Feishu bridge daemon.
# Judges CONNECTION liveness, not process liveness:
#   - heartbeat file stale (>180s)            -> daemon wedged
#   - ws_state != connected and no successful
#     connection for >300s                    -> WS link dead
# Restarts feishu-bridge.service at most once per 10 minutes.
# Pure shell + python3 stdlib; no tokens, no network.
set -u
BASE="/root/workspace/feishu-bridge"
HB="$BASE/state/heartbeat.json"
LOG="$BASE/ops/watchdog.log"
STAMP="$BASE/ops/watchdog_last_restart"

verdict="$(python3 - "$HB" <<'PY'
import json, sys, time
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        hb = json.load(f)
except Exception:
    print("restart heartbeat_unreadable")
    raise SystemExit
now = int(time.time())
if now - int(hb.get("ts") or 0) > 180:
    print("restart heartbeat_stale")
    raise SystemExit
if hb.get("ws_state") not in (None, "connected"):
    last = hb.get("ws_last_connected_ts") or hb.get("started_at") or now
    if now - int(last) > 300:
        print("restart ws_down state=%s gap=%ds" % (hb.get("ws_state"), now - int(last)))
        raise SystemExit
print("ok")
PY
)"

case "$verdict" in
  ok*) exit 0 ;;
  restart*)
    now="$(date +%s)"
    last=0
    [ -f "$STAMP" ] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
    if [ $((now - last)) -lt 600 ]; then
      echo "$(date -u +%FT%TZ) skip cooldown verdict=$verdict" >> "$LOG"
      exit 0
    fi
    echo "$now" > "$STAMP"
    echo "$(date -u +%FT%TZ) restart verdict=$verdict" >> "$LOG"
    systemctl restart feishu-bridge.service
    ;;
  *) echo "$(date -u +%FT%TZ) unknown verdict=$verdict" >> "$LOG" ;;
esac
exit 0
