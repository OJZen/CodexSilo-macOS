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
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT_DIR/build/release}"
TAG_PREFIX="${TAG_PREFIX:-}"
RELEASE_TITLE_PREFIX="${RELEASE_TITLE_PREFIX:-CodexSilo}"
PUSH_TAG="${PUSH_TAG:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"

log() {
  printf '[publish_release] %s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

infer_repository() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$remote_url" ]] || fail "Could not determine origin remote"

  case "$remote_url" in
    git@github.com:*)
      remote_url="${remote_url#git@github.com:}"
      remote_url="${remote_url%.git}"
      ;;
    https://github.com/*)
      remote_url="${remote_url#https://github.com/}"
      remote_url="${remote_url%.git}"
      ;;
    *)
      fail "Unsupported GitHub remote URL: $remote_url"
      ;;
  esac

  printf '%s' "$remote_url"
}

read_build_setting() {
  local key="$1"
  xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings \
    | awk -F' = ' -v key="$key" '$1 ~ key {print $2; exit}'
}

latest_artifact_for_version() {
  local version="$1"
  local candidate

  candidate="$(find "$OUTPUT_ROOT" -maxdepth 1 -type f -name "*-${version}-macOS-notarized.zip" -print -quit)"
  if [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi

  candidate="$(find "$OUTPUT_ROOT" -maxdepth 1 -type f -name "*-${version}-macOS-signed.zip" -print -quit)"
  if [[ -n "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi

  fail "Could not find a release artifact for version ${version} under ${OUTPUT_ROOT}"
}

require_command git
require_command gh
require_command xcodebuild

gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"

if [[ "$ALLOW_DIRTY" != "1" ]]; then
  git diff --quiet && git diff --cached --quiet || fail "Working tree is not clean. Commit or stash changes before publishing."
fi

APP_VERSION="$(read_build_setting "MARKETING_VERSION")"
[[ -n "$APP_VERSION" ]] || fail "Could not read MARKETING_VERSION from Xcode build settings"

TAG_NAME="${TAG_PREFIX}${APP_VERSION}"
REPOSITORY="$(infer_repository)"

if [[ "$SKIP_BUILD" != "1" ]]; then
  log "Building and notarizing release artifact"
  "$ROOT_DIR/scripts/release_macos.sh"
fi

ARTIFACT_PATH="$(latest_artifact_for_version "$APP_VERSION")"
CHECKSUM_PATH="${ARTIFACT_PATH}.sha256"
[[ -f "$CHECKSUM_PATH" ]] || fail "Missing checksum file for artifact: $CHECKSUM_PATH"

if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  log "Tag already exists locally: $TAG_NAME"
else
  log "Creating git tag: $TAG_NAME"
  git tag "$TAG_NAME"
fi

if [[ "$PUSH_TAG" == "1" ]]; then
  log "Pushing tag to origin"
  git push origin "$TAG_NAME"
fi

if gh release view "$TAG_NAME" --repo "$REPOSITORY" >/dev/null 2>&1; then
  log "Release already exists, uploading artifacts with overwrite"
  gh release upload "$TAG_NAME" "$ARTIFACT_PATH" "$CHECKSUM_PATH" --clobber --repo "$REPOSITORY"
else
  log "Creating GitHub release"
  gh release create "$TAG_NAME" "$ARTIFACT_PATH" "$CHECKSUM_PATH" \
    --repo "$REPOSITORY" \
    --title "${RELEASE_TITLE_PREFIX} ${APP_VERSION}" \
    --generate-notes
fi

log "Done"
log "Repository: $REPOSITORY"
log "Tag: $TAG_NAME"
log "Artifact: $ARTIFACT_PATH"
