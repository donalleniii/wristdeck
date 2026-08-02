#!/bin/zsh
# WristDeck Notch build helper. Modes:
#   ./build.sh            regenerate project and build
#   ./build.sh run        build, then (re)launch the menu-bar app
#   ./build.sh install    build and copy to /Applications
#   ./build.sh login      install + register as a login item
#   ./build.sh xcode      regenerate project and open in Xcode
set -e
cd "$(dirname "$0")"

if [ -d "/Applications/Xcode-beta.app" ]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi

APP="build/Build/Products/Debug/WristDeckNotch.app"

gen() { xcodegen generate --quiet; }

build() {
  gen
  xcodebuild -project WristDeckNotch.xcodeproj -scheme WristDeckNotch \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build -quiet build
  echo "build ok: $APP"
}

relaunch() {
  pkill -x WristDeckNotch 2>/dev/null || true
  sleep 0.5
  open "$1"
  echo "launched: $1"
}

case "${1:-build}" in
  build) build ;;
  xcode) gen && open WristDeckNotch.xcodeproj ;;
  run)
    build
    relaunch "$APP"
    ;;
  install)
    build
    pkill -x WristDeckNotch 2>/dev/null || true
    rm -rf /Applications/WristDeckNotch.app
    cp -R "$APP" /Applications/
    relaunch /Applications/WristDeckNotch.app
    ;;
  login)
    "$0" install
    osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/WristDeckNotch.app", hidden:true}' >/dev/null
    echo "registered as a login item"
    ;;
  *) echo "usage: ./build.sh [build|run|install|login|xcode]"; exit 1 ;;
esac
