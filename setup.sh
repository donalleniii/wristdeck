#!/bin/zsh
# WristDeck one-shot setup. Idempotent; re-run any time. Flags: --rotate (new token)
set -e
cd "$(dirname "$0")"

TS=/usr/local/bin/tailscale
[ -x "$TS" ] || TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
NODE=$(command -v node || echo /opt/homebrew/bin/node)
LABEL="com.donalleniii.wristdeck.bridge"

echo "== 0/6 local identity =="
# Everything machine-specific lives in local.env, which is gitignored. The
# repo itself carries no team id, no device id, and no tailnet address.
LOCAL_ENV="$(pwd)/local.env"
if [ ! -f "$LOCAL_ENV" ]; then
  cat > "$LOCAL_ENV" <<'LOCALEOF'
# Machine-specific settings. Never commit this file.
# Your Apple Developer Team ID: Xcode > Settings > Accounts, or
# https://developer.apple.com/account (Membership details).
DEVELOPMENT_TEAM=
# Optional: your Apple Watch's device id. Leave blank to auto-detect the
# paired watch when installing.
WATCH_ID=
LOCALEOF
  echo "   created local.env"
fi
# shellcheck disable=SC1090
. "$LOCAL_ENV"
if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  echo "   ACTION NEEDED: set DEVELOPMENT_TEAM in local.env, then re-run."
  echo "   Find it in Xcode > Settings > Accounts, or developer.apple.com/account."
  exit 1
fi
echo "   team ${DEVELOPMENT_TEAM}"

echo "== 1/6 bridge dependencies =="
(cd bridge && npm install --no-fund --no-audit --silent)

echo "== 2/6 auth token =="
if [ ! -f bridge/.env ] || [ "$1" = "--rotate" ]; then
  TOKEN=$(openssl rand -hex 32)
  printf 'WRISTDECK_TOKEN=%s\nPORT=8787\n' "$TOKEN" > bridge/.env
  chmod 600 bridge/.env
  echo "   wrote new token to bridge/.env"
else
  echo "   keeping existing bridge/.env"
fi
TOKEN=$(grep '^WRISTDECK_TOKEN=' bridge/.env | cut -d= -f2)

echo "== 3/6 tailscale funnel =="
FUNNEL_URL=""
if "$TS" status > /dev/null 2>&1; then
  # `funnel --bg` blocks forever waiting for approval when Funnel is not yet
  # enabled on the tailnet, so cap it and surface the approval URL instead.
  "$TS" funnel --bg 8787 > /tmp/wristdeck-funnel.txt 2>&1 &
  FUNNEL_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 $FUNNEL_PID 2>/dev/null || break
    sleep 1
  done
  kill $FUNNEL_PID 2>/dev/null || true
  if grep -q 'not enabled' /tmp/wristdeck-funnel.txt 2>/dev/null; then
    echo "   ACTION NEEDED: Funnel is not enabled on your tailnet yet."
    grep -oE 'https://login\.tailscale\.com/\S+' /tmp/wristdeck-funnel.txt | head -1 | sed 's/^/   open: /'
    echo "   Approve it in the browser, then re-run ./setup.sh"
  fi
  FUNNEL_URL=$("$TS" funnel status 2>/dev/null | grep -oE 'https://[a-z0-9.-]+\.ts\.net' | head -1)
  echo "   funnel URL: ${FUNNEL_URL:-not active yet (local Wi-Fi still works)}"
else
  echo "   Tailscale is not connected; log in via the menu bar app and re-run for remote access."
fi

echo "== 4/6 watch Config.plist =="
LOCAL_URL="http://$(scutil --get LocalHostName).local:8787"
# Raw LAN IP as well: watchOS mDNS (.local) resolution is unreliable.
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
LAN_URL=""
[ -n "$LAN_IP" ] && LAN_URL="http://${LAN_IP}:8787"
# Tailscale IP: works from anywhere IF the watch's traffic traverses the tailnet
# (e.g. relayed through a paired iPhone running Tailscale). Costs nothing to try,
# since the app health-races every candidate and keeps the first that answers.
TS_IP=$("$TS" ip -4 2>/dev/null | head -1)
TS_URL=""
[ -n "$TS_IP" ] && TS_URL="http://${TS_IP}:8787"
cat > watch/Sources/Config.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BridgeURL</key>
	<string>${FUNNEL_URL}</string>
	<key>TailscaleURL</key>
	<string>${TS_URL}</string>
	<key>LanURL</key>
	<string>${LAN_URL}</string>
	<key>LocalURL</key>
	<string>${LOCAL_URL}</string>
	<key>Token</key>
	<string>${TOKEN}</string>
</dict>
</plist>
PLIST
chmod 600 watch/Sources/Config.plist
echo "   BridgeURL=${FUNNEL_URL:-<none>}  TailscaleURL=${TS_URL:-<none>}"
echo "   LanURL=${LAN_URL:-<none>}  LocalURL=${LOCAL_URL}"

echo "== 5/6 Xcode projects =="
# project.yml is GENERATED from a template so the repo carries no team id and no
# tailnet address. watchOS refuses cleartext to Tailscale's 100.64.0.0/10 range
# without an explicit ATS exception, hence substituting the real IP here.
render_project() {
  sed -e "s|__DEVELOPMENT_TEAM__|${DEVELOPMENT_TEAM}|g" \
      -e "s|__TAILSCALE_IP__|${TS_IP:-100.64.0.1}|g" \
      "$1" > "$2"
}
render_project watch/project.template.yml watch/project.yml
render_project mac/project.template.yml mac/project.yml
echo "   team ${DEVELOPMENT_TEAM}, tailnet ${TS_IP:-<none>}"

echo "== 6/6 launchd service =="
mkdir -p "$HOME/Library/Logs/wristdeck" "$HOME/Library/LaunchAgents"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${NODE}</string>
		<string>$(pwd)/bridge/src/server.ts</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$(pwd)/bridge</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/bin:/bin</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${HOME}/Library/Logs/wristdeck/bridge.log</string>
	<key>StandardErrorPath</key>
	<string>${HOME}/Library/Logs/wristdeck/bridge.err.log</string>
</dict>
</plist>
PLIST
# bootout is async: bootstrapping too soon fails with "Input/output error" and
# leaves the bridge DOWN. Wait for the old job to disappear, then verify health.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/${LABEL}" > /dev/null 2>&1 || break
  sleep 1
done
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null \
  || launchctl kickstart -k "gui/$(id -u)/${LABEL}" 2>/dev/null \
  || true

BRIDGE_OK=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS --max-time 2 -H "Authorization: Bearer ${TOKEN}" \
      "http://127.0.0.1:8787/health" > /dev/null 2>&1; then
    BRIDGE_OK=yes
    break
  fi
  sleep 1
done
if [ -n "$BRIDGE_OK" ]; then
  echo "   bridge service running and healthy (logs: ~/Library/Logs/wristdeck/)"
else
  echo "   WARNING: bridge did not come up. Check ~/Library/Logs/wristdeck/bridge.err.log"
fi

echo ""
echo "Done. Funnel URL: ${FUNNEL_URL:-none}   Token: ${TOKEN:0:8}..."
echo "Next: cd watch && ./build.sh device   (watch unlocked, on wrist)"
