#!/bin/bash

#
#  release.sh
#  yina
#
#  Builds, verifies, signs and publishes a yina release from this Mac.
#
#  This replaces the CI release workflow: GitHub's macOS runners do not ship the
#  Xcode SDK this project builds against, so releases are produced locally where
#  the toolchain, the signing identity and the Sparkle key all live.
#
#  Usage:
#    other/release.sh [--dry-run]
#
#  --dry-run  build, verify and sign, but do not publish, tag or push.
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REMOTE="${YINA_RELEASE_REMOTE:-yina}"
readonly DERIVED_DATA="${YINA_RELEASE_DERIVED:-/tmp/yina-release}"
readonly SPARKLE_BIN="$REPO_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
readonly RELEASE_OUT="$DERIVED_DATA/release"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '4,20p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
  esac
done

cd "$REPO_DIR"

# The release version is the single VERSION file. Never guess it.
VERSION_FILE="$REPO_DIR/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
  echo "VERSION file is missing: $VERSION_FILE" >&2
  exit 66
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ -z "$VERSION" ]; then
  echo "VERSION file is empty. A release needs an explicit version." >&2
  exit 66
fi

TAG="v$VERSION"

echo "==> Releasing yina $VERSION ($TAG)"

if ! git rev-parse --verify "$TAG" >/dev/null 2>&1; then
  :
else
  echo "Tag $TAG already exists locally. Bump VERSION before releasing again." >&2
  exit 65
fi

# Only the meh line may be released. The repository also carries upstream IINA
# tags, and releasing one of those would publish upstream code as yina.
if ! git merge-base --is-ancestor HEAD "origin/meh" 2>/dev/null; then
  echo "HEAD is not on origin/meh; refusing to release." >&2
  echo "Fetch first: git fetch $REMOTE meh" >&2
  exit 65
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty; refusing to release a moving target." >&2
  git status --short >&2
  exit 65
fi

# Sparkle must be able to sign, otherwise the published feed would offer an
# update that every client rejects. Fail before building rather than after.
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "Sparkle tools are missing: $SPARKLE_BIN" >&2
  echo "Run a build once so SwiftPM populates SourcePackages." >&2
  exit 66
fi
if ! "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
  echo "No Sparkle signing key in the login keychain; refusing to release." >&2
  echo "Generate one with: $SPARKLE_BIN/generate_keys" >&2
  exit 65
fi
echo "==> Sparkle signing key found"

mkdir -p "$RELEASE_OUT"

echo "==> Building Release configuration"
xcodebuild \
  -project yina.xcodeproj \
  -scheme yina \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$REPO_DIR/SourcePackages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=27.0 \
  CODE_SIGNING_ALLOWED=NO \
  YINA_VERSION="$VERSION" \
  build

APP="$DERIVED_DATA/Build/Products/Release/yina.app"
test -d "$APP" || { echo "Build did not produce $APP" >&2; exit 1; }

# vtool rewrites every Mach-O, so normalize and verify before anything is signed.
"$SCRIPT_DIR/modernize_arm64_bundle.sh" "$APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$APP"

# Release builds are ad-hoc signed (CODE_SIGN_IDENTITY = - in Deployment.xcconfig).
# Sparkle's update signature is independent of this and is what clients verify.
echo "==> Signing bundle (ad-hoc)"
while IFS= read -r -d '' path; do
  if file -b "$path" | grep -q "Mach-O"; then
    codesign --force --sign - "$path"
  fi
done < <(find "$APP" -type f -print0)

while IFS= read -r -d '' path; do
  case "$path" in
    "$APP") ;;
    *.app|*.appex|*.framework|*.xpc|*.bundle)
      codesign --force --sign - "$path"
      ;;
  esac
done < <(find "$APP" -depth -type d -print0)

codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating Sparkle update archive"
ARCHIVE="$RELEASE_OUT/yina-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ARCHIVE" | tail -1)"
if [ -z "$SIGNATURE" ]; then
  echo "sign_update produced no signature; refusing to publish." >&2
  exit 1
fi
echo "==> Signature: $SIGNATURE"

ENCLOSURE_URL="https://github.com/$(git config --get remote.$REMOTE.url | sed -E 's|.*[:/]([^/]+)/([^/.]+)(\.git)?$|\1/\2|')/releases/download/$TAG/yina-$VERSION.zip"
echo "==> Enclosure URL: $ENCLOSURE_URL"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry run complete. Nothing was published."
  echo "  version:   $VERSION"
  echo "  archive:   $ARCHIVE"
  echo "  signature: $SIGNATURE"
  echo "  appcast:   would describe $ENCLOSURE_URL"
  exit 0
fi

APPCAST="$RELEASE_OUT/appcast.xml"
"$SCRIPT_DIR/write_appcast.sh" "$APPCAST" "$ENCLOSURE_URL" "$VERSION" "$SIGNATURE" "$ARCHIVE"

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "yina $VERSION"

echo "==> Publishing release"
gh release create "$TAG" \
  --repo "$(git config --get remote.$REMOTE.url)" \
  --title "yina $VERSION" \
  --notes "yina $VERSION" \
  "$ARCHIVE"

echo "==> Pushing tag"
git push "$REMOTE" "$TAG"

echo "==> Publishing appcast to gh-pages"
"$SCRIPT_DIR/publish_appcast.sh" "$APPCAST" "$RELEASE_OUT" "$REMOTE"

echo
echo "Released yina $VERSION"
