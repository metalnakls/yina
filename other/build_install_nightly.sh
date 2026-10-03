#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly INSTALL_APP="/Applications/yina.app"
readonly BACKUP_DIR="$(cd "$REPO_DIR/.." && pwd)/.build-backups"
readonly BACKUP_APP="$BACKUP_DIR/yina.app"
readonly DERIVED_DATA="${1:-/tmp/yina-nightly-final}"
readonly BUILD_APP="$DERIVED_DATA/Build/Products/Nightly/yina.app"
readonly MODULE_CACHE_DIR="$DERIVED_DATA/ModuleCache.noindex"
readonly SWIFTPM_CACHE_DIR="$DERIVED_DATA/SwiftPMCache"
readonly DEFAULT_SOURCE_PACKAGES_DIR="$REPO_DIR/SourcePackages"
readonly IINA_ENTITLEMENTS="$REPO_DIR/yina/yina.entitlements"
readonly OPEN_IN_IINA_ENTITLEMENTS="$REPO_DIR/OpenInYINA/OpenInYINA.entitlements"
readonly DEFAULT_SIGN_IDENTITY="919F9538E1E91B7C10FD2556CC9030B76ED39E58"

SIGN_IDENTITY="${IINA_CODESIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
SOURCE_PACKAGES_DIR="${IINA_SOURCE_PACKAGES_DIR:-$DEFAULT_SOURCE_PACKAGES_DIR}"

if (( $# > 1 )); then
  echo "usage: $0 [derived-data-path]" >&2
  exit 64
fi

cd "$REPO_DIR"

if [[ ! -d "$SOURCE_PACKAGES_DIR/checkouts" ]]; then
  echo "Missing local Swift package checkouts: $SOURCE_PACKAGES_DIR/checkouts" >&2
  exit 66
fi

if ! security find-identity -v -p codesigning | awk -v identity="$SIGN_IDENTITY" 'index($0, identity) { found = 1 } END { exit !found }'; then
  echo "The requested Apple Development signing identity is unavailable in this execution context: $SIGN_IDENTITY" >&2
  echo "Retry this build with approved elevated local/keychain access. Keep the signing private key in the macOS Keychain; do not substitute another identity." >&2
  exit 65
fi

mkdir -p "$MODULE_CACHE_DIR" "$SWIFTPM_CACHE_DIR"

# yina uses one version number for both CFBundleVersion and CFBundleShortVersionString.
# Sparkle compares CFBundleVersion, so it must rise for every release. Local builds
# derive a date-based version so debugging never dirties the tree; releases set
# YINA_VERSION explicitly from the VERSION file at the repository root.
# See AGENTS.md for the bump rule.
if [ -n "${YINA_VERSION:-}" ]; then
  BUILD_VERSION="$YINA_VERSION"
else
  BUILD_VERSION="$(date -u +%Y%m%d%H%M)"
fi

# Keep compiler and SwiftPM caches with the build products. The host cache locations
# are not guaranteed to be writable, and using the checked-out package graph keeps
# this install build deterministic and offline.
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

xcodebuild \
  -project yina.xcodeproj \
  -scheme yina \
  -configuration Nightly \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -packageCachePath "$SWIFTPM_CACHE_DIR" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  YINA_VERSION="$BUILD_VERSION" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=27.0 \
  CODE_SIGNING_ALLOWED=NO \
  build

test -d "$BUILD_APP"
"$SCRIPT_DIR/modernize_arm64_bundle.sh" "$BUILD_APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$BUILD_APP"

# vtool changes every Mach-O, so sign only after the final bundle layout exists.
# Sign nested code before its enclosing bundle; never use codesign --deep.
while IFS= read -r -d '' path; do
  if file -b "$path" | grep -q "Mach-O"; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime "$path"
  fi
done < <(find "$BUILD_APP" -type f -print0)

while IFS= read -r -d '' path; do
  case "$path" in
    "$BUILD_APP") ;;
    */OpenInYINA.appex)
      codesign --force --sign "$SIGN_IDENTITY" --options runtime \
        --entitlements "$OPEN_IN_IINA_ENTITLEMENTS" "$path"
      ;;
    *.app|*.appex|*.framework|*.xpc|*.bundle)
      codesign --force --sign "$SIGN_IDENTITY" --options runtime "$path"
      ;;
  esac
done < <(find "$BUILD_APP" -depth -type d -print0)

codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --entitlements "$IINA_ENTITLEMENTS" "$BUILD_APP"
codesign --verify --deep --strict --verbose=2 "$BUILD_APP"

# Preserve the last known installed build before updating the stable wrapper.
# The wrapper stays in place; only its contents are refreshed.
if test -x "$INSTALL_APP/Contents/MacOS/yina"; then
  mkdir -p "$BACKUP_APP"
  find "$BACKUP_APP" -mindepth 1 -delete
  ditto "$INSTALL_APP" "$BACKUP_APP"
  codesign --verify --deep --strict "$BACKUP_APP"
fi

# This script owns one exact install destination. Preserve the app bundle itself
# and replace only its contents.
test "$INSTALL_APP" = "/Applications/yina.app"
mkdir -p "$INSTALL_APP"
find "$INSTALL_APP" -mindepth 1 -delete
ditto "$BUILD_APP" "$INSTALL_APP"

codesign --verify --deep --strict "$INSTALL_APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$INSTALL_APP"

# Keep exactly the rotating backup. This runs only after the new installed bundle
# has verified, so a build or signing failure never removes a recoverable app.
if [[ -d "$BACKUP_DIR" ]]; then
  while IFS= read -r -d '' path; do
    if [[ "$path" != "$BACKUP_APP" ]]; then
      rm -rf -- "$path"
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'yina*.app' -print0)
fi

echo "Installed $INSTALL_APP"
