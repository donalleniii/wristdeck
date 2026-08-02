#!/bin/zsh
# WristDeck build helper. Modes:
#   ./build.sh            regenerate project and build for the watch simulator
#   ./build.sh test       sim build + boot a watch sim + install + auto smoke + screenshot
#   ./build.sh device     signed build + install onto the paired Apple Watch
#   ./build.sh xcode      regenerate project and open in Xcode
set -e
cd "$(dirname "$0")"

# Prefer the Xcode 27 beta stack when present (matches the watchOS 26 device).
if [ -d "/Applications/Xcode-beta.app" ]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

BUNDLE="com.donalleniii.wristdeck"

# Which watch to install onto. Set WATCH_ID in ../local.env to pin a specific
# device; otherwise the first paired physical Apple Watch is used.
[ -f ../local.env ] && . ../local.env
resolve_watch() {
  if [ -n "${WATCH_ID:-}" ]; then echo "$WATCH_ID"; return; fi
  xcrun devicectl list devices 2>/dev/null \
    | grep -i 'Apple Watch' | grep -i 'physical' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
    | head -1
}

gen() { xcodegen generate --quiet; }

build_sim() {
  gen
  xcodebuild -project WristDeck.xcodeproj -scheme WristDeck \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath build -quiet build CODE_SIGNING_ALLOWED=NO
  echo "sim build ok: build/Build/Products/Debug-watchsimulator/WristDeck.app"
}

build_device() {
  gen
  xcodebuild -project WristDeck.xcodeproj -scheme WristDeck \
    -destination 'generic/platform=watchOS' \
    -derivedDataPath build -quiet -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration build
  echo "device build ok: build/Build/Products/Debug-watchos/WristDeck.app"
}

sim_install() {
  SIM=$(xcrun simctl list devices available | grep -i "apple watch" | head -1 | grep -oE '[0-9A-F-]{36}')
  if [ -z "$SIM" ]; then echo "no watch simulator found"; exit 1; fi
  xcrun simctl bootstatus "$SIM" -b
  xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$SIM" build/Build/Products/Debug-watchsimulator/WristDeck.app
}

case "${1:-sim}" in
  sim) build_sim ;;
  xcode) gen && open WristDeck.xcodeproj ;;
  device)
    build_device
    TARGET=$(resolve_watch)
    if [ -z "$TARGET" ]; then
      echo "no paired Apple Watch found. Pair one, or set WATCH_ID in ../local.env"
      exit 1
    fi
    # Device tunnels drop constantly if the watch dozes; retry rather than
    # making the user re-run and wonder whether the build was the problem.
    for attempt in 1 2 3 4 5 6; do
      if xcrun devicectl device install app --device "$TARGET" \
           build/Build/Products/Debug-watchos/WristDeck.app 2>&1 | grep -q 'App installed'; then
        echo "installed on the watch (attempt $attempt)"
        exit 0
      fi
      echo "  attempt $attempt failed; keep the watch unlocked and on your wrist"
    done
    echo "could not reach the watch. Unlock it, keep the screen awake, and retry."
    exit 1
    ;;
  test)
    build_sim
    sim_install
    xcrun simctl launch "$SIM" "$BUNDLE" -autoSmoke "http://127.0.0.1:8787"
    sleep 8
    xcrun simctl io "$SIM" screenshot /tmp/wristdeck-test.png
    echo "screenshot: /tmp/wristdeck-test.png"
    xcrun simctl spawn "$SIM" log show --last 2m --info \
      --predicate 'subsystem == "com.donalleniii.wristdeck"' | grep -i smoke || true
    ;;
  *) echo "usage: ./build.sh [sim|test|device|xcode]"; exit 1 ;;
esac
