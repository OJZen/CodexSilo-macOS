#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-CodexSilo.xcodeproj}"
SCHEME="${SCHEME:-CodexSilo}"
CONFIGURATION="${CONFIGURATION:-Release}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-KLU8GF65GP}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Ning Huang (KLU8GF65GP)}"
SIGNING_STYLE="${SIGNING_STYLE:-Automatic}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-}"
AUTO_DETECT_PROFILE="${AUTO_DETECT_PROFILE:-1}"
RELEASE_ROOT="${RELEASE_ROOT:-$ROOT_DIR/artifacts/macos-release}"
WORK_ROOT="${WORK_ROOT:-}"
KEEP_WORK_ROOT="${KEEP_WORK_ROOT:-0}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.alick.codexsilo}"
NOTARIZE_WITH="${NOTARIZE_WITH:-auto}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
CREATE_GITHUB_RELEASE="${CREATE_GITHUB_RELEASE:-0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-AlickH/CodexSilo}"
GH_RELEASE_NOTES="${GH_RELEASE_NOTES:-}"

log() {
  printf '[release_macos] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

ensure_clean_dir() {
  rm -rf "$1"
  mkdir -p "$1"
}

cleanup_work_root() {
  if [[ "${KEEP_WORK_ROOT}" == "1" || -z "${WORK_ROOT:-}" ]]; then
    return
  fi

  rm -rf "$WORK_ROOT"
}

decode_profile_to_plist() {
  local profile_path="$1"
  local plist_path="$2"

  security cms -D -i "$profile_path" >"$plist_path" 2>/dev/null
}

extract_plist_value() {
  local plist_path="$1"
  local key_path="$2"

  /usr/libexec/PlistBuddy -c "Print ${key_path}" "$plist_path" 2>/dev/null
}

resolve_provisioning_profile_specifier() {
  local profile_dir
  local profile_path
  local plist_path
  local name
  local team_id
  local app_identifier
  local provisions_all_devices
  local bundle_identifier_suffix
  local tmp_dir

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexsilo-profile-scan.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN

  for profile_dir in \
    "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  do
    [[ -d "$profile_dir" ]] || continue

    while IFS= read -r -d '' profile_path; do
      plist_path="$tmp_dir/profile.plist"
      decode_profile_to_plist "$profile_path" "$plist_path" || continue

      name="$(extract_plist_value "$plist_path" ":Name")"
      team_id="$(extract_plist_value "$plist_path" ":TeamIdentifier:0")"
      app_identifier="$(extract_plist_value "$plist_path" ":Entitlements:com.apple.application-identifier")"
      provisions_all_devices="$(extract_plist_value "$plist_path" ":ProvisionsAllDevices")"

      if [[ -z "$name" || -z "$team_id" || -z "$app_identifier" ]]; then
        continue
      fi

      if [[ "$team_id" != "$DEVELOPMENT_TEAM" ]]; then
        continue
      fi

      if [[ "$provisions_all_devices" != "true" ]]; then
        continue
      fi

      bundle_identifier_suffix="${app_identifier#${team_id}.}"
      if [[ "$bundle_identifier_suffix" == "$PRODUCT_BUNDLE_IDENTIFIER" && "$name" == *"Developer ID"* ]]; then
        printf '%s' "$name"
        return 0
      fi
    done < <(find "$profile_dir" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0)
  done

  return 1
}

pick_notarization_backend() {
  case "$NOTARIZE_WITH" in
    asc|notarytool|skip)
      printf '%s' "$NOTARIZE_WITH"
      ;;
    auto)
      if command -v asc >/dev/null 2>&1 && asc auth whoami >/dev/null 2>&1; then
        printf 'asc'
      elif [[ -n "$NOTARY_PROFILE" ]]; then
        printf 'notarytool'
      else
        printf 'skip'
      fi
      ;;
    *)
      printf 'Invalid NOTARIZE_WITH value: %s\n' "$NOTARIZE_WITH" >&2
      exit 1
      ;;
  esac
}

write_export_options() {
  if [[ "$SIGNING_STYLE" == "Manual" && -z "$PROVISIONING_PROFILE_SPECIFIER" ]]; then
    printf 'PROVISIONING_PROFILE_SPECIFIER is required when SIGNING_STYLE=Manual\n' >&2
    exit 1
  fi

  cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>${SIGNING_STYLE,,}</string>
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
EOF

  if [[ "$SIGNING_STYLE" == "Manual" ]]; then
    cat >>"$EXPORT_OPTIONS_PLIST" <<EOF
  <key>signingCertificate</key>
  <string>${CODESIGN_IDENTITY}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${PRODUCT_BUNDLE_IDENTIFIER}</key>
    <string>${PROVISIONING_PROFILE_SPECIFIER}</string>
  </dict>
EOF
  fi

  cat >>"$EXPORT_OPTIONS_PLIST" <<EOF
</dict>
</plist>
EOF
}

release_notes() {
  if [[ -n "$GH_RELEASE_NOTES" ]]; then
    printf '%s' "$GH_RELEASE_NOTES"
    return
  fi

  cat <<EOF
macOS release for CodexSilo ${APP_VERSION}.

Notes:
- Built from commit ${GIT_COMMIT}.
- Signed with ${CODESIGN_IDENTITY}.
- Notarization backend: ${NOTARIZATION_BACKEND}.
EOF
}

if [[ -z "$WORK_ROOT" ]]; then
  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codexsilo-release.XXXXXX")"
fi

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$WORK_ROOT/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_ROOT/$SCHEME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$WORK_ROOT/export}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$WORK_ROOT/ExportOptions.plist}"

trap cleanup_work_root EXIT

require_command xcodebuild
require_command codesign
require_command ditto
require_command plutil
require_command shasum

NOTARIZATION_BACKEND="$(pick_notarization_backend)"
GIT_COMMIT="$(git rev-parse HEAD)"

if [[ "$NOTARIZATION_BACKEND" == "asc" ]]; then
  require_command asc
fi

if [[ "$NOTARIZATION_BACKEND" == "notarytool" ]]; then
  require_command xcrun
  if [[ -z "$NOTARY_PROFILE" ]]; then
    printf 'NOTARY_PROFILE is required when NOTARIZE_WITH=notarytool\n' >&2
    exit 1
  fi
fi

case "$SIGNING_STYLE" in
  Automatic|Manual)
    ;;
  *)
    printf 'Invalid SIGNING_STYLE value: %s\n' "$SIGNING_STYLE" >&2
    exit 1
    ;;
esac

if [[ "$SIGNING_STYLE" == "Automatic" && "$AUTO_DETECT_PROFILE" == "1" && -z "$PROVISIONING_PROFILE_SPECIFIER" ]]; then
  if PROVISIONING_PROFILE_SPECIFIER="$(resolve_provisioning_profile_specifier)"; then
    SIGNING_STYLE="Manual"
    log "Resolved Developer ID provisioning profile: $PROVISIONING_PROFILE_SPECIFIER"
  fi
fi

log "Preparing release directories"
ensure_clean_dir "$RELEASE_ROOT"
mkdir -p "$WORK_ROOT"
rm -rf "$DERIVED_DATA_PATH" "$ARCHIVE_PATH" "$EXPORT_PATH"
find "$RELEASE_ROOT" -maxdepth 1 -type d -name 'export*' -exec rm -rf {} +
write_export_options

ARCHIVE_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -destination "generic/platform=macOS"
  archive
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  CODE_SIGN_STYLE="$SIGNING_STYLE"
)

if [[ "$SIGNING_STYLE" == "Manual" ]]; then
  ARCHIVE_ARGS+=("CODE_SIGN_IDENTITY=$CODESIGN_IDENTITY")
  ARCHIVE_ARGS+=("PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_SPECIFIER")
fi

log "Archiving macOS app"
xcodebuild "${ARCHIVE_ARGS[@]}"

EXPORT_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
)

log "Exporting Developer ID app bundle"
xcodebuild "${EXPORT_ARGS[@]}"

APP_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  printf 'No exported .app bundle found in %s\n' "$EXPORT_PATH" >&2
  exit 1
fi

log "Verifying code signature"
codesign --verify --deep --strict --verbose=5 "$APP_PATH"
codesign -dvvv "$APP_PATH" >/dev/null

APP_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
APP_BUILD="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)"
APP_NAME="$(basename "$APP_PATH" .app)"
ZIP_NAME="${APP_NAME}-${APP_VERSION}-macOS-signed.zip"
ZIP_PATH="$RELEASE_ROOT/$ZIP_NAME"
SHA_PATH="$ZIP_PATH.sha256"
SIGNED_ZIP_PATH="$ZIP_PATH"
SIGNED_SHA_PATH="$SHA_PATH"

log "Packaging release zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
printf '  %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" "$(basename "$ZIP_PATH")" >"$SHA_PATH"

case "$NOTARIZATION_BACKEND" in
  asc)
    log "Submitting zip for notarization with asc"
    asc notarization submit --file "$ZIP_PATH" --wait
    log "Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    ZIP_NAME="${APP_NAME}-${APP_VERSION}-macOS-notarized.zip"
    ZIP_PATH="$RELEASE_ROOT/$ZIP_NAME"
    SHA_PATH="$ZIP_PATH.sha256"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    printf '  %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" "$(basename "$ZIP_PATH")" >"$SHA_PATH"
    rm -f "$SIGNED_ZIP_PATH" "$SIGNED_SHA_PATH"
    ;;
  notarytool)
    log "Submitting zip for notarization with notarytool profile '$NOTARY_PROFILE'"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    log "Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    ZIP_NAME="${APP_NAME}-${APP_VERSION}-macOS-notarized.zip"
    ZIP_PATH="$RELEASE_ROOT/$ZIP_NAME"
    SHA_PATH="$ZIP_PATH.sha256"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    printf '  %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" "$(basename "$ZIP_PATH")" >"$SHA_PATH"
    rm -f "$SIGNED_ZIP_PATH" "$SIGNED_SHA_PATH"
    ;;
  skip)
    log "Skipping notarization"
    ;;
esac

if [[ "$CREATE_GITHUB_RELEASE" == "1" ]]; then
  require_command gh
  TAG="v${APP_VERSION}"
  TITLE="CodexSilo ${APP_VERSION}"
  NOTES_FILE="$RELEASE_ROOT/release-notes.txt"
  release_notes >"$NOTES_FILE"

  if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    log "Uploading assets to existing GitHub release $TAG"
    gh release upload "$TAG" "$ZIP_PATH" "$SHA_PATH" --clobber --repo "$GITHUB_REPOSITORY"
  else
    log "Creating GitHub release $TAG"
    gh release create \
      "$TAG" \
      "$ZIP_PATH" \
      "$SHA_PATH" \
      --repo "$GITHUB_REPOSITORY" \
      --target "$GIT_COMMIT" \
      --title "$TITLE" \
      --notes-file "$NOTES_FILE"
  fi
fi

log "Done"
log "Version: ${APP_VERSION} (${APP_BUILD})"
log "App: $APP_PATH"
log "Zip: $ZIP_PATH"
log "SHA256: $SHA_PATH"
