#!/usr/bin/env bash
# Capture App Store screenshots of the demo apartment in the simulator, then compose marketing frames.
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { cat <<USAGE
Usage: scripts/screenshots.sh [--raw-only] [--output DIR]

Builds a Debug simulator app, then for each device (iPhone 6.9" and iPad 13")
launches the demo apartment with -openDemo/-openSheet, sets a clean status bar
and captures: map, perspective, inspector, optimizer, equipment.
Then composes framed marketing images (EN + pt-PT) with scripts/screenshots/compose.py
(needs Python 3 with Pillow: pip3 install pillow).

  --output DIR  Output root (default: ./build/screenshots) -> raw/ and final/
  --raw-only    Skip composing.

Environment:
  IPHONE_SIM    default "iPhone 17 Pro Max"   (1320x2868)
  IPAD_SIM      default "iPad Pro 13-inch (M5)" (2064x2752)
USAGE
}
OUT="$ROOT/build/screenshots"; RAWONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) [[ $# -ge 2 ]] || die "--output needs a directory"; OUT="$2"; shift ;;
    --raw-only) RAWONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done
"$ROOT/scripts/build.sh"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$APP_NAME.app"

# Take screenshots until consecutive frames match (UI settled), max ~30 s.
wait_stable() {
  local udid="$1" out="$2" need="${3:-1}" prev="" cur matches=0 i tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' RETURN
  sleep 2
  for i in $(seq 1 15); do
    xcrun simctl io "$udid" screenshot "$tmp/f.png" >/dev/null 2>&1 || { sleep 2; continue; }
    cur=$(shasum "$tmp/f.png" | awk '{print $1}')
    if [[ -n "$prev" && "$cur" == "$prev" ]]; then
      matches=$((matches + 1))
      if (( matches >= need )); then break; fi
    else
      matches=0
    fi
    prev="$cur"; sleep 2
  done
  mv "$tmp/f.png" "$out"
}

shoot() {
  local name="$1" dir="$2" udid
  udid=$(SIMULATOR="$name" pick_simulator)
  mkdir -p "$dir"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl install "$udid" "$APP"
  for s in map perspective inspector optimizer equipment; do
    local extra=() need=1
    [[ $s != map ]] && extra=(-openSheet "$s")
    [[ $s == optimizer ]] && need=2
    xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" \
      -AppleLanguages "(en)" -AppleLocale en_US -openDemo ${extra[@]+"${extra[@]}"} >/dev/null
    wait_stable "$udid" "$dir/$s.png" "$need"
    info "$name: $s"
  done
  xcrun simctl status_bar "$udid" clear 2>/dev/null || true
}
shoot "${IPHONE_SIM:-iPhone 17 Pro Max}" "$OUT/raw/iphone"
shoot "${IPAD_SIM:-iPad Pro 13-inch (M5)}" "$OUT/raw/ipad"

if (( ! RAWONLY )); then
  python3 -c "import PIL" 2>/dev/null || die "Pillow not installed (pip3 install pillow), or rerun with --raw-only."
  python3 "$ROOT/scripts/screenshots/compose.py" "$OUT/raw" "$OUT/final"
fi
info "Screenshots in $OUT"
