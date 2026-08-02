#!/bin/zsh
# Keeps this Mac awake so WristDeck stays reachable from the watch.
#
# Why this matters beyond screenshots: when the Mac sleeps, the bridge stops
# answering, so anything sent from the wrist simply never arrives.
#
# Battery-aware ON PURPOSE. Holding the display on while unplugged drains a
# laptop fast, and a Mac on battery in a bag is not serving requests anyway. On
# AC it stays fully awake; on battery it releases the assertion and lets macOS
# do its normal thing.
#
#   ./keepawake.sh run       foreground loop (what launchd runs)
#   ./keepawake.sh install   start at login and now
#   ./keepawake.sh uninstall stop and remove
#   ./keepawake.sh status    what is it doing right now
#   ./keepawake.sh always    keep awake even on battery (drains it)
set -e
cd "$(dirname "$0")"

LABEL="com.donalleniii.wristdeck.keepawake"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
FORCE_FLAG="$HOME/.wristdeck-keepawake-always"

on_ac() { pmset -g batt 2>/dev/null | grep -q "AC Power"; }

run_loop() {
  CAFF_PID=""
  cleanup() { [ -n "$CAFF_PID" ] && kill "$CAFF_PID" 2>/dev/null; exit 0; }
  trap cleanup INT TERM

  while true; do
    WANT=no
    if [ -f "$FORCE_FLAG" ] || on_ac; then WANT=yes; fi

    if [ "$WANT" = yes ]; then
      if [ -z "$CAFF_PID" ] || ! kill -0 "$CAFF_PID" 2>/dev/null; then
        # -d display, -i idle system, -m disk. NOT -s: that is AC-only anyway
        # and we are already gating on power ourselves.
        /usr/bin/caffeinate -dim &
        CAFF_PID=$!
        echo "$(date '+%H:%M:%S') holding awake (pid $CAFF_PID)"
      fi
    else
      if [ -n "$CAFF_PID" ] && kill -0 "$CAFF_PID" 2>/dev/null; then
        kill "$CAFF_PID" 2>/dev/null || true
        echo "$(date '+%H:%M:%S') on battery, released"
      fi
      CAFF_PID=""
    fi
    sleep 30
  done
}

case "${1:-status}" in
  run) run_loop ;;

  install)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/wristdeck"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>$(pwd)/keepawake.sh</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${HOME}/Library/Logs/wristdeck/keepawake.log</string>
	<key>StandardErrorPath</key>
	<string>${HOME}/Library/Logs/wristdeck/keepawake.log</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || break
      sleep 1
    done
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed. Awake on AC power, normal sleep on battery."
    echo "To keep awake on battery too: ./keepawake.sh always"
    ;;

  uninstall)
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST" "$FORCE_FLAG"
    pkill -f 'caffeinate -dim' 2>/dev/null || true
    echo "removed. Normal sleep behavior restored."
    ;;

  always)
    touch "$FORCE_FLAG"
    echo "will now stay awake on battery too (this drains it). Undo: ./keepawake.sh acOnly"
    ;;

  acOnly)
    rm -f "$FORCE_FLAG"
    echo "back to AC-power-only."
    ;;

  status)
    if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
      echo "keepawake: installed"
    else
      echo "keepawake: not installed"
    fi
    on_ac && echo "power: AC" || echo "power: battery"
    [ -f "$FORCE_FLAG" ] && echo "mode: always (even on battery)" || echo "mode: AC power only"
    if pgrep -f 'caffeinate -dim' >/dev/null 2>&1; then
      echo "currently holding the Mac awake"
    else
      echo "not currently holding (normal sleep applies)"
    fi
    ;;

  *) echo "usage: ./keepawake.sh [install|uninstall|status|always|acOnly|run]"; exit 1 ;;
esac
