#!/usr/bin/env bash
# Signed Release archive + App Store .ipa export, optional upload to App Store Connect.
set -euo pipefail
source "$(dirname "$0")/common.sh"

usage() { cat <<USAGE
Usage: scripts/archive.sh [--upload] [--output DIR]

Archives the app (Release) with automatic signing and exports an App Store
Connect .ipa. Xcode creates certificates and profiles as needed
(-allowProvisioningUpdates); you must be signed in to Xcode with the team.
Requires Xcode $MIN_XCODE+ with the iOS $MIN_XCODE SDK.

Every run writes to a new directory and never deletes anything it did not
create in this run.

  --output DIR  Directory for the .ipa. It must not exist yet (or be empty);
                it is created. Default: ./build/ipa-<timestamp>
  --upload      Upload the .ipa with altool. Requires:
                  ASC_KEY_ID     App Store Connect API key ID
                  ASC_ISSUER_ID  API issuer ID
                and AuthKey_<ASC_KEY_ID>.p8 in a folder altool searches
                (e.g. ~/.appstoreconnect/private_keys/), or ASC_KEY_DIR
                pointing at the folder that contains it.

Environment:
  TEAM_ID       Apple Developer team ID (default: DEVELOPMENT_TEAM in project.yml).
USAGE
}
UPLOAD=0; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload) UPLOAD=1 ;;
    --output) [[ $# -ge 2 ]] || die "--output needs a directory"; OUT="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done
TEAM=$(team_id)
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "No valid team ID. Set TEAM_ID or DEVELOPMENT_TEAM in project.yml."
if (( UPLOAD )); then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || die "--upload needs ASC_KEY_ID and ASC_ISSUER_ID."
fi

STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$ROOT/build"
if [[ -z "$OUT" ]]; then
  OUT=$(mktemp -d "$ROOT/build/ipa-$STAMP-XXXX")
else
  if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" && -r "$OUT" && -x "$OUT" ]] || die "--output $OUT is not a readable directory."
    LISTING=$(find "$OUT/" -mindepth 1 -maxdepth 1) || die "cannot list --output $OUT."
    [[ -z "$LISTING" ]] \
      || die "--output $OUT already exists and is not empty. Choose a new directory; nothing is deleted."
  else
    mkdir -p "$OUT"
  fi
  OUT=$(cd "$OUT" && pwd)
fi
WORK=$(mktemp -d "$ROOT/build/archive-$STAMP-XXXX")   # created by us; holds archive, logs, plist

require_xcode
generate
ARCHIVE="$WORK/$APP_NAME.xcarchive"
info "Archiving (team $TEAM) into $WORK"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" archive >"$WORK/archive.log" 2>&1 \
  || { grep -E "error:" "$WORK/archive.log" | awk 'NR<=20' >&2 || true; die "archive failed. Log: $WORK/archive.log"; }

OPTS="$WORK/ExportOptions.plist"
cat >"$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
info "Exporting App Store .ipa to $OUT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist "$OPTS" -allowProvisioningUpdates >"$WORK/export.log" 2>&1 \
  || { grep -E "error" "$WORK/export.log" | awk 'NR<=20' >&2 || true; die "export failed. Log: $WORK/export.log (accept any pending agreement at developer.apple.com)"; }
IPA=$(find "$OUT/" -maxdepth 1 -name '*.ipa' | awk 'NR==1')
[[ -n "$IPA" ]] || die "export produced no .ipa in $OUT"
info "Exported $IPA"

if (( UPLOAD )); then
  if [[ -n "${ASC_KEY_DIR:-}" ]]; then export API_PRIVATE_KEYS_DIR="$ASC_KEY_DIR"; fi
  info "Uploading to App Store Connect"
  xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
fi
