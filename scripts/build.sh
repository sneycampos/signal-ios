#!/usr/bin/env bash
# Generate the project and build the app. Simulator Debug build by default, no signing.
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { cat <<USAGE
Usage: scripts/build.sh [--device] [--release] [--run] [--demo] [--no-generate]

  (default)      Build for the iOS Simulator, Debug, no signing.
  --device       Build for a generic iOS device with CODE_SIGNING_ALLOWED=NO
                 (compile check only; the result cannot be installed).
  --release      Use the Release configuration.
  --run          Boot a simulator, install and launch the app (simulator only).
  --demo         With --run: launch with -openDemo (Debug builds only).
  --no-generate  Skip xcodegen generate.

Environment:
  SIMULATOR      Simulator name to use with --run (default: first available iPhone).
  DERIVED_DATA   DerivedData path (default: ./build/DerivedData).
USAGE
}

DEVICE=0; CONFIG=Debug; RUN=0; DEMO=0; GEN=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=1 ;;
    --release) CONFIG=Release ;;
    --run) RUN=1 ;;
    --demo) DEMO=1 ;;
    --no-generate) GEN=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done
if (( DEVICE && RUN )); then die "--run only works with simulator builds (drop --device)."; fi
if (( DEMO && ! RUN )); then die "--demo needs --run."; fi
if [[ "$CONFIG" == Release && $DEMO -eq 1 ]]; then die "-openDemo is only honoured in Debug builds; drop --release or --demo."; fi
require_xcode
if (( GEN )); then generate; fi
if (( DEVICE )); then DEST='generic/platform=iOS'; SDKDIR=iphoneos
else DEST='generic/platform=iOS Simulator'; SDKDIR=iphonesimulator; fi

info "Building $SCHEME ($CONFIG, $DEST)"
LOG="$ROOT/build/build.log"; mkdir -p "$ROOT/build"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination "$DEST" -derivedDataPath "$DERIVED" \
      CODE_SIGNING_ALLOWED=NO build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | awk 'NR<=20' >&2 || true
  die "build failed. Full log: $LOG"
fi
APP="$DERIVED/Build/Products/$CONFIG-$SDKDIR/$APP_NAME.app"
info "Built $APP"

if (( RUN )); then
  UDID=$(pick_simulator)
  info "Booting simulator $UDID"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  open "$(xcode-select -p)/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
  ARGS=(); (( DEMO )) && ARGS+=(-openDemo)
  info "Launching $BUNDLE_ID ${ARGS[*]:-}"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} >/dev/null
fi
