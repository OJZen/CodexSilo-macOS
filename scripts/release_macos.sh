#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f "$ROOT_DIR/.release.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.release.env"
  set +a
fi

PROJECT_PATH="${PROJECT_PATH:-CodexSilo.xcodeproj}"
SCHEME="${SCHEME:-CodexSilo}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT_DIR/build/release}"
NOTARIZE="${NOTARIZE:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"
KEEP_WORK_ROOT="${KEEP_WORK_ROOT:-0}"
WORK_ROOT="${WORK_ROOT:-}"

log() {
  printf '[release_macos] %s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
  if [[ "$KEEP_WORK_ROOT" == "1" ]]; then
    log "Keeping temporary work directory: $WORK_ROOT"
    return
  fi

  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]]; then
    rm -rf "$WORK_ROOT"
  fi
}

write_export_options() {
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
EOF
    if [[ -n "$DEVELOPMENT_TEAM" ]]; then
      cat <<EOF
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
EOF
    fi
    cat <<'EOF'
</dict>
</plist>
EOF
  } >"$EXPORT_OPTIONS_PLIST"
}

read_plist_value() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print ${key}" "$plist_path" 2>/dev/null || true
}

if [[ -z "$WORK_ROOT" ]]; then
  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codexsilo-release.XXXXXX")"
fi

trap cleanup EXIT

ARCHIVE_PATH="$WORK_ROOT/$SCHEME.xcarchive"
EXPORT_PATH="$WORK_ROOT/export"
EXPORT_OPTIONS_PLIST="$WORK_ROOT/ExportOptions.plist"
SUBMISSION_ZIP="$WORK_ROOT/notary-submission.zip"
NOTARY_RESPONSE_JSON="$WORK_ROOT/notarytool-submit.json"

require_command xcodebuild
require_command xcrun
require_command ditto
require_command shasum
require_command codesign
require_command /usr/libexec/PlistBuddy

if [[ "$NOTARIZE" == "1" && -z "$NOTARY_PROFILE" ]]; then
  fail "NOTARY_PROFILE is required when NOTARIZE=1"
fi

mkdir -p "$OUTPUT_ROOT"
write_export_options

log "Archiving $SCHEME"
archive_cmd=(
  xcodebuild
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -archivePath "$ARCHIVE_PATH"
)
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  archive_cmd+=(-allowProvisioningUpdates)
fi
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  archive_cmd+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi
if [[ -n "$PRODUCT_BUNDLE_IDENTIFIER" ]]; then
  archive_cmd+=(PRODUCT_BUNDLE_IDENTIFIER="$PRODUCT_BUNDLE_IDENTIFIER")
fi
archive_cmd+=(archive)
"${archive_cmd[@]}"

log "Exporting Developer ID build"
export_cmd=(
  xcodebuild
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  export_cmd+=(-allowProvisioningUpdates)
fi
"${export_cmd[@]}"

APP_PATH="$(find "$EXPORT_PATH" -maxdepth 2 -type d -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || fail "Export did not produce a .app bundle"

APP_NAME="$(basename "$APP_PATH" .app)"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(read_plist_value "$INFO_PLIST" ':CFBundleShortVersionString')"
APP_BUILD="$(read_plist_value "$INFO_PLIST" ':CFBundleVersion')"
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="${APP_BUILD:-0.0.0}"
fi

log "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

log "Creating notarization submission archive"
rm -f "$SUBMISSION_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

FINAL_ARTIFACT="$OUTPUT_ROOT/${APP_NAME}-${APP_VERSION}-macOS-signed.zip"

if [[ "$NOTARIZE" == "1" ]]; then
  log "Submitting archive for notarization"
  submit_cmd=(
    xcrun
    notarytool
    submit
    "$SUBMISSION_ZIP"
    --keychain-profile "$NOTARY_PROFILE"
    --wait
    --output-format json
  )
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    submit_cmd+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  "${submit_cmd[@]}" >"$NOTARY_RESPONSE_JSON"

  log "Stapling notarization ticket"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"

  FINAL_ARTIFACT="$OUTPUT_ROOT/${APP_NAME}-${APP_VERSION}-macOS-notarized.zip"
fi

log "Creating release artifact"
rm -f "$FINAL_ARTIFACT" "$FINAL_ARTIFACT.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ARTIFACT"
shasum -a 256 "$FINAL_ARTIFACT" >"$FINAL_ARTIFACT.sha256"

log "Done"
log "Artifact: $FINAL_ARTIFACT"
log "Checksum: $FINAL_ARTIFACT.sha256"
if [[ "$KEEP_WORK_ROOT" == "1" ]]; then
  log "Exported app bundle: $APP_PATH"
fi
