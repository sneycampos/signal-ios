#!/usr/bin/env bash
# Run the end-to-end XCUITest suite (SignalUITests) in the iOS Simulator.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DERIVED="${DERIVED_DATA:-/tmp/mp-uitests-dd}"
UI_SCHEME="SignalUITests"

usage() { cat <<USAGE
Usage: scripts/ui-test.sh [--headless] [--no-generate]

  (default)      Generate the project, boot an iPhone simulator, open the
                 Simulator app visibly, and run the SignalUITests XCUITest suite.
  --headless     Do not open the Simulator app window.
  --no-generate  Skip xcodegen generate.

Environment:
  SIMULATOR      Simulator name to use (default: first available iPhone).
  DERIVED_DATA   DerivedData path (default: /tmp/mp-uitests-dd).
USAGE
}

HEADLESS=0; GEN=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless) HEADLESS=1 ;;
    --no-generate) GEN=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done

if [[ "$DERIVED" == "/tmp/mp-device-dd" ]]; then
  die "Refusing to use /tmp/mp-device-dd (reserved for device builds). Use DERIVED_DATA=/tmp/mp-uitests-dd."
fi

require_xcode
if (( GEN )); then generate; fi

UDID=$(pick_simulator)
info "Booting simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
if (( ! HEADLESS )); then
  open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null || true
fi

LOG="$ROOT/build/ui-test.log"
mkdir -p "$ROOT/build"
info "Running $UI_SCHEME on simulator $UDID (DerivedData: $DERIVED)"
START_SECONDS=$SECONDS
set +e
xcodebuild test -project "$PROJECT" -scheme "$UI_SCHEME" \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO >"$LOG" 2>&1
STATUS=$?
set -e
RUNTIME=$(( SECONDS - START_SECONDS ))

PASSED=$(grep -cE "^Test Case '.*' passed \(" "$LOG" || true)
FAILED=$(grep -cE "^Test Case '.*' failed \(" "$LOG" || true)
SKIPPED=$(grep -cE "^Test Case '.*' skipped \(" "$LOG" || true)

grep -E "^Test Case '.*' (passed|failed|skipped) \(" "$LOG" || true

if (( STATUS == 0 )); then
  info "PASS: $PASSED passed, $SKIPPED skipped, $FAILED failed (runtime: ${RUNTIME}s)"
else
  grep -E "(error:|Executed [0-9]+ test|failed \()" "$LOG" | tail -n 25 >&2 || true
  info "FAIL: $PASSED passed, $SKIPPED skipped, $FAILED failed (runtime: ${RUNTIME}s). Full log: $LOG"
  exit "$STATUS"
fi
