#!/usr/bin/env bash
# Check the toolchain, install XcodeGen if needed and generate the Xcode project.
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { cat <<USAGE
Usage: scripts/bootstrap.sh [--help]

Checks that Xcode 26+ with the iOS 26+ SDK is installed and selected, installs XcodeGen with Homebrew
when it is missing, and generates Signal.xcodeproj from project.yml. Safe to rerun.
USAGE
}
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then usage; exit 0; fi
[[ $# -eq 0 ]] || { usage; die "unknown argument: $1"; }

require_xcode
info "Found $(xcodebuild -version | awk 'NR==1'), iOS SDK $(xcrun --sdk iphoneos --show-sdk-version) ($(xcode-select -p))"

if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Install it from https://brew.sh or install XcodeGen manually: https://github.com/yonaskolb/XcodeGen"
  info "Installing XcodeGen with Homebrew"
  brew install xcodegen
fi
info "XcodeGen $(xcodegen --version 2>/dev/null | sed 's/Version: //')"

generate
info "Done. Next: ./scripts/build.sh --run"
