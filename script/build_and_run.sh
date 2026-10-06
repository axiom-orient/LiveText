#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
usage() {
  echo "usage: $0 [run|--export [directory]|--benchmark [directory]|--verify|--debug|--logs|--telemetry]"
}
case "$MODE" in
  -h|--help) usage; exit 0 ;;
  run|--export|--benchmark|--verify|--debug|--logs|--telemetry) ;;
  *) usage >&2; exit 2 ;;
esac
case "$MODE" in
  --export|--benchmark)
    if (( $# > 2 )); then usage >&2; exit 2; fi
    ;;
  *) if (( $# > 1 )); then usage >&2; exit 2; fi ;;
esac

APP_NAME="LiveTextDemo"
BUNDLE_ID="local.livetext.demo"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"

cd "$ROOT_DIR"
if pgrep -x "$APP_NAME" >/dev/null; then pkill -x "$APP_NAME"; fi
BUILD_CONFIGURATION="debug"
if [[ "$MODE" == --benchmark ]]; then BUILD_CONFIGURATION="release"; fi
swift build -c "$BUILD_CONFIGURATION" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_CONTENTS/MacOS/$APP_NAME"
for resource in "$BIN_DIR"/*.bundle; do
  if [[ -d "$resource" ]]; then cp -R "$resource" "$APP_CONTENTS/Resources/"; fi
done
cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --export)
    "$APP_CONTENTS/MacOS/$APP_NAME" --export "${2:-$ROOT_DIR/.build/demo-output}"
    ;;
  --benchmark)
    "$APP_CONTENTS/MacOS/$APP_NAME" --benchmark "${2:-$ROOT_DIR/.build/demo-benchmark}"
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --debug) lldb -- "$APP_CONTENTS/MacOS/$APP_NAME" ;;
  --logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
esac
