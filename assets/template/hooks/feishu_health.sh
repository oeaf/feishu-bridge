#!/usr/bin/env bash
# Feishu bridge health detector with script self-heal.
# Silent (0 tokens) while healthy. If heartbeat stale or processes missing,
# tries start_bridge.sh once inside the script; wakes an agent only when
# the script-level restart did not recover the bridge (max 1 wake / 30 min).
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

BRIDGE="$HOME/workspace/feishu-bridge"
HB="$BRIDGE/state/heartbeat.json"
SHB="$BRIDGE/state/supervisor_heartbeat.json"
NOW="$(date +%s)"

hb_age() { # $1 = heartbeat file -> age in seconds, 999999 if unreadable
  local f="$1" ts=0
  if [[ -f "$f" ]]; then
    ts="$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("ts",0)))' "$f" 2>/dev/null || echo 0)"
  fi
  if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -gt 0 ]]; then
    echo $(( $(date +%s) - ts ))
  else
    echo 999999
  fi
}

procs_ok() {
  pgrep -f "supervisor\.py" >/dev/null 2>&1 && pgrep -f "bridge_daemon" >/dev/null 2>&1
}

DAEMON_AGE="$(hb_age "$HB")"
SUP_AGE="$(hb_age "$SHB")"

if [[ "$DAEMON_AGE" -le 120 ]] && [[ "$SUP_AGE" -le 120 ]] && procs_ok; then
  silent "feishu bridge healthy" "{\"daemon_age\":$DAEMON_AGE,\"supervisor_age\":$SUP_AGE}"
  exit 0
fi

# Stale -> script self-heal. local_file mode: start_bridge.sh self-reads
# the local credentials file; this script never touches secrets.
log "feishu_bridge_stale" "{\"daemon_age\":$DAEMON_AGE,\"supervisor_age\":$SUP_AGE}"
if [[ -x "$BRIDGE/bridge/start_bridge.sh" ]]; then
  "$BRIDGE/bridge/start_bridge.sh" >/dev/null 2>&1 || true
  sleep 20
  DAEMON_AGE="$(hb_age "$HB")"
  if [[ "$DAEMON_AGE" -le 120 ]] && procs_ok; then
    log "feishu_bridge_selfhealed" "{\"daemon_age\":$DAEMON_AGE}"
    silent "feishu bridge self-healed by restart script" "{\"daemon_age\":$DAEMON_AGE}"
    exit 0
  fi
fi

# Still down -> wake an agent, at most once per 30 minutes.
STATE="$(hook_state_get 2>/dev/null || echo '{}')"
LAST="$(printf '%s' "$STATE" | python3 -c 'import json,sys
try:
  print(int(json.load(sys.stdin).get("alerted_at",0)))
except Exception:
  print(0)' 2>/dev/null || echo 0)"
NOW="$(date +%s)"
if [[ "$LAST" =~ ^[0-9]+$ ]] && [[ "$LAST" -gt 0 ]] && [[ $((NOW - LAST)) -lt 1800 ]]; then
  silent "feishu bridge down, already alerted recently" "{\"daemon_age\":$DAEMON_AGE}"
  exit 0
fi
hook_state_set "{\"alerted_at\":$NOW}" >/dev/null 2>&1 || true
wake "feishu bridge down and script restart did not recover it" "{\"daemon_age\":$DAEMON_AGE,\"supervisor_age\":$SUP_AGE}"
