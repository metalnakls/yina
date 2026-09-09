#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly INSTALL_APP="/Applications/Utilities/IINA.app"
readonly BACKUP_APP="$REPO_DIR/../.build-backups/IINA.app"
readonly DERIVED_DATA="${1:-/tmp/iina-nightly-final}"
readonly BUILD_APP="$DERIVED_DATA/Build/Products/Nightly/IINA.app"

if (( $# > 1 )); then
  echo "usage: $0 [derived-data-path]" >&2
  exit 64
fi

cd "$REPO_DIR"

xcodebuild \
  -project iina.xcodeproj \
  -scheme iina \
  -configuration Nightly \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=27.0 \
  CODE_SIGNING_ALLOWED=NO \
  build

test -d "$BUILD_APP"
"$SCRIPT_DIR/modernize_arm64_bundle.sh" "$BUILD_APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$BUILD_APP"
codesign --force --deep --sign - "$BUILD_APP"
codesign --verify --deep --strict "$BUILD_APP"

# This script owns one exact install destination. Never generalize this removal.
test "$INSTALL_APP" = "/Applications/Utilities/IINA.app"
if test -x "$INSTALL_APP/Contents/MacOS/IINA"; then
  mkdir -p "$BACKUP_APP"
  find "$BACKUP_APP" -mindepth 1 -delete
  ditto "$INSTALL_APP" "$BACKUP_APP"
fi
mkdir -p "$INSTALL_APP"
find "$INSTALL_APP" -mindepth 1 -delete
ditto "$BUILD_APP" "$INSTALL_APP"

codesign --verify --deep --strict "$INSTALL_APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$INSTALL_APP"
echo "Installed $INSTALL_APP"
