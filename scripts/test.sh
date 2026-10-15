#!/usr/bin/env bash
# Run the SignalCore test suite (Swift Testing, on macOS) and optionally the verification runner.
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { cat <<USAGE
Usage: scripts/test.sh [--runner] [--build-app]

  (default)    swift test  (SignalCore unit tests, runs on macOS)
  --runner     Also run the command-line verification/benchmark:
               swift run -c release SignalTestRunner
  --build-app  Also compile the iOS app for the simulator (scripts/build.sh),
               to catch errors in SignalUI, which swift test does not build.

The Xcode project has no XCTest target; all tests live in the Swift package.
USAGE
}
RUNNER=0; APP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner) RUNNER=1 ;;
    --build-app) APP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done
command -v swift >/dev/null 2>&1 || die "swift not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
cd "$ROOT"
info "swift test"
swift test
if (( RUNNER )); then info "SignalTestRunner"; swift run -c release SignalTestRunner; fi
if (( APP )); then "$ROOT/scripts/build.sh"; fi
info "All tests passed"
