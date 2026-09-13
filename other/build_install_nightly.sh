#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly INSTALL_APP="/Applications/Utilities/IINA.app"
readonly DERIVED_DATA="${1:-/tmp/iina-nightly-final}"
readonly BUILD_APP="$DERIVED_DATA/Build/Products/Nightly/IINA.app"
readonly MODULE_CACHE_DIR="$DERIVED_DATA/ModuleCache.noindex"
readonly SWIFTPM_CACHE_DIR="$DERIVED_DATA/SwiftPMCache"
readonly SOURCE_PACKAGES_DIR="$REPO_DIR/SourcePackages"
readonly IINA_ENTITLEMENTS="$REPO_DIR/iina/IINA.entitlements"
readonly OPEN_IN_IINA_ENTITLEMENTS="$REPO_DIR/OpenInIINA/OpenInIINA.entitlements"
readonly DEVELOPMENT_TEAM="67CQ77V27R"

SIGN_IDENTITY="${IINA_CODESIGN_IDENTITY:-}"

if (( $# > 1 )); then
  echo "usage: $0 [derived-data-path]" >&2
  exit 64
fi

cd "$REPO_DIR"

if [[ ! -d "$SOURCE_PACKAGES_DIR/checkouts" ]]; then
  echo "Missing local Swift package checkouts: $SOURCE_PACKAGES_DIR/checkouts" >&2
  exit 66
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning |
      awk -F '"' "/Apple Development:.*\\(${DEVELOPMENT_TEAM}\\)/ { print \$2; exit }"
  )"
fi

if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  echo "No Apple Development signing identity for team $DEVELOPMENT_TEAM was found." >&2
  echo "Install one in Xcode, or set IINA_CODESIGN_IDENTITY to an explicit valid identity." >&2
  exit 65
fi

mkdir -p "$MODULE_CACHE_DIR" "$SWIFTPM_CACHE_DIR"

# Keep compiler and SwiftPM caches with the build products. The host cache locations
# are not guaranteed to be writable, and using the checked-out package graph keeps
# this install build deterministic and offline.
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

xcodebuild \
  -project iina.xcodeproj \
  -scheme iina \
  -configuration Nightly \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -packageCachePath "$SWIFTPM_CACHE_DIR" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
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
    */OpenInIINA.appex)
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

# This script owns one exact install destination. Preserve the app bundle itself
# and replace only its contents.
test "$INSTALL_APP" = "/Applications/Utilities/IINA.app"
mkdir -p "$INSTALL_APP"
find "$INSTALL_APP" -mindepth 1 -delete
ditto "$BUILD_APP" "$INSTALL_APP"

codesign --verify --deep --strict "$INSTALL_APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$INSTALL_APP"
echo "Installed $INSTALL_APP"
