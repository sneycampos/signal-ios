# shellcheck shell=bash
# Shared helpers. Sourced by the other scripts.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Signal.xcodeproj"
SCHEME="Signal"
BUNDLE_ID="com.silviogodinho.signal"
DERIVED="${DERIVED_DATA:-$ROOT/build/DerivedData}"
APP_NAME="Signal"          # PRODUCT_NAME of the app target (display name: Mesh Planner)
MIN_XCODE=26

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_xcode() {
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
  xcode-select -p 2>/dev/null | grep -q "Xcode" || die "xcode-select points to the Command Line Tools. Run: sudo xcode-select -s /Applications/Xcode.app"
  local xc major sdk
  xc=$(xcodebuild -version | awk 'NR==1')
  major=$(echo "$xc" | sed -E 's/^Xcode ([0-9]+).*/\1/')
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= MIN_XCODE )) || die "Xcode $MIN_XCODE or newer is required (App Store submissions need the iOS $MIN_XCODE SDK). Found: $xc"
  sdk=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0)
  (( ${sdk%%.*} >= MIN_XCODE )) || die "iOS $MIN_XCODE SDK or newer is required. Found: iOS SDK $sdk. Install it in Xcode > Settings > Components."
}

# Team ID: TEAM_ID env var, else DEVELOPMENT_TEAM from project.yml.
team_id() {
  if [[ -n "${TEAM_ID:-}" ]]; then echo "$TEAM_ID"; return; fi
  awk -F'"' '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$ROOT/project.yml"
}

require_xcodegen() {
  command -v xcodegen >/dev/null 2>&1 || die "XcodeGen not found. Run ./scripts/bootstrap.sh (or: brew install xcodegen)"
}

generate() {
  require_xcodegen
  info "Generating Signal.xcodeproj from project.yml"
  (cd "$ROOT" && xcodegen generate --quiet)
}

# Available simulators whose iOS runtime meets the deployment target (17).
simulators() {
  xcrun simctl list devices available | awk '/^-- iOS / { split($3, v, "."); ok = (v[1] + 0 >= 17); next } /^-- / { ok = 0; next } ok'
}

# Pick an available iPhone simulator (override with SIMULATOR="iPhone 17 Pro").
pick_simulator() {
  local name="${SIMULATOR:-}"
  local line
  if [[ -n "$name" ]]; then
    line=$(simulators | grep -F "    $name (" | tail -n 1 || true)
    [[ -n "$line" ]] || die "No available simulator named '$name'. See: xcrun simctl list devices available"
  else
    line=$(simulators | grep -E "^ +iPhone" | tail -n 1 || true)
    [[ -n "$line" ]] || die "No iPhone simulator available. Install an iOS runtime in Xcode > Settings > Components."
  fi
  echo "$line" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}
