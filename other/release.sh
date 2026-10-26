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
readonly REPO="metalnakls/yina"
readonly REMOTE="${YINA_RELEASE_REMOTE:-yina}"
readonly DERIVED_DATA="${YINA_RELEASE_DERIVED:-/tmp/yina-release}"
readonly SPARKLE_BIN="$REPO_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
readonly RELEASE_OUT="$DERIVED_DATA/release"
readonly MEDIA_SIGNING_DIR="$DERIVED_DATA/MediaExtensionSigning"
readonly RELEASE_SIGN_IDENTITY="${YINA_RELEASE_CODESIGN_IDENTITY:-}"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
source "$SCRIPT_DIR/even-git-time.sh"

unregister_release_app() {
  if [[ -d "$DERIVED_DATA/Build/Products/Release/yina.app" ]]; then
    "$LSREGISTER" -u "$DERIVED_DATA/Build/Products/Release/yina.app" >/dev/null 2>&1 || true
  fi
}
trap unregister_release_app EXIT

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '4,20p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
  esac
done

cd "$REPO_DIR"

# Media Extensions use restricted entitlements. Ad-hoc signing produces an app
# that verifies locally but macOS refuses to load, so never publish that artifact.
if [[ ! "$RELEASE_SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] ||
   ! security find-identity -v -p codesigning | awk -v identity="$RELEASE_SIGN_IDENTITY" 'index($0, identity) && index($0, "Developer ID Application:") { found = 1 } END { exit !found }'; then
  echo "Set YINA_RELEASE_CODESIGN_IDENTITY to an explicit valid Developer ID Application certificate SHA-1. Media Extensions cannot be distributed with ad-hoc signing." >&2
  exit 65
fi
python3 "$SCRIPT_DIR/prepare_media_extension_signing.py" \
  --identity "$RELEASE_SIGN_IDENTITY" --output "$MEDIA_SIGNING_DIR"

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

echo "==> Validating managed defaults"
python3 "$SCRIPT_DIR/publish_defaults.py" "$REPO_DIR/yina/ManagedDefaults.json" >/dev/null

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
if [ "$(git branch --show-current)" != meh ]; then
  echo "Releases must be built from the meh branch; refusing to release." >&2
  exit 65
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
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
KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
BUNDLE_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$REPO_DIR/yina/Info.plist")"
if [ "$KEYCHAIN_PUBLIC_KEY" != "$BUNDLE_PUBLIC_KEY" ]; then
  echo "Sparkle signing key does not match the app public key; refusing to release." >&2
  exit 65
fi
echo "==> Sparkle signing key matches the app"

if [ "$DRY_RUN" -eq 0 ]; then
  git fetch "$REMOTE" meh
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$REMOTE/meh")" ]; then
    echo "Push the reviewed meh commit before publishing a release." >&2
    exit 65
  fi
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists; bump VERSION." >&2
    exit 65
  fi
fi

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
cp "$MEDIA_SIGNING_DIR/formatreader.provisionprofile" "$APP/Contents/Extensions/yinaFormats.appex/Contents/embedded.provisionprofile"
cp "$MEDIA_SIGNING_DIR/videodecoder.provisionprofile" "$APP/Contents/Extensions/yinaCodecs.appex/Contents/embedded.provisionprofile"

# vtool rewrites every Mach-O, so normalize and verify before anything is signed.
"$SCRIPT_DIR/modernize_arm64_bundle.sh" "$APP"
"$SCRIPT_DIR/verify_arm64_bundle.sh" "$APP"

# Sparkle's update signature is independent of the Developer ID signature and
# the embedded Media Extension provisioning profiles required by macOS.
echo "==> Signing bundle (Developer ID)"
while IFS= read -r -d '' path; do
  if file -b "$path" | grep -q "Mach-O"; then
    codesign --force --sign "$RELEASE_SIGN_IDENTITY" --options runtime "$path"
  fi
done < <(find "$APP" -type f -print0)

while IFS= read -r -d '' path; do
  case "$path" in
    "$APP") ;;
    */OpenInYINA.appex)
      codesign --force --sign "$RELEASE_SIGN_IDENTITY" --options runtime --entitlements "$REPO_DIR/OpenInYINA/OpenInYINA.entitlements" "$path"
      ;;
    */yinaFormats.appex)
      codesign --force --sign "$RELEASE_SIGN_IDENTITY" --options runtime --entitlements "$MEDIA_SIGNING_DIR/formatreader.entitlements" "$path"
      ;;
    */yinaCodecs.appex)
      codesign --force --sign "$RELEASE_SIGN_IDENTITY" --options runtime --entitlements "$MEDIA_SIGNING_DIR/videodecoder.entitlements" "$path"
      ;;
    *.app|*.appex|*.framework|*.xpc|*.bundle|*.mdimporter)
      codesign --force --sign "$RELEASE_SIGN_IDENTITY" --options runtime "$path"
      ;;
  esac
done < <(find "$APP" -depth -type d -print0)

codesign --force --sign "$RELEASE_SIGN_IDENTITY" --options runtime --entitlements "$REPO_DIR/yina/yina.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

for key in CFBundleVersion CFBundleShortVersionString; do
  if [ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")" != "$VERSION" ]; then
    echo "Built app $key does not match VERSION; refusing to release." >&2
    exit 65
  fi
done

echo "==> Creating Sparkle update archive"
ARCHIVE="$RELEASE_OUT/yina.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

SIGNATURE_LINE="$("$SPARKLE_BIN/sign_update" "$ARCHIVE")"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGNATURE_LINE")"
if [ -z "$SIGNATURE" ]; then
  echo "sign_update produced no signature; refusing to publish." >&2
  exit 1
fi
"$SPARKLE_BIN/sign_update" --verify "$ARCHIVE" "$SIGNATURE"

ENCLOSURE_URL="https://github.com/$REPO/releases/download/$TAG/yina.zip"
echo "==> Enclosure URL: $ENCLOSURE_URL"

APPCAST="$RELEASE_OUT/appcast.xml"
"$SCRIPT_DIR/write_appcast.sh" "$APPCAST" "$ENCLOSURE_URL" "$VERSION" "$SIGNATURE" "$ARCHIVE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry run complete. Nothing was published."
  echo "  version:   $VERSION"
  echo "  archive:   $ARCHIVE"
  echo "  signature: $SIGNATURE"
  echo "  appcast:   would describe $ENCLOSURE_URL"
  exit 0
fi

echo "==> Tagging $TAG"
wait_for_even_git_minute
GIT_TAG_DATE="$(nearest_even_git_timestamp)"
GIT_AUTHOR_DATE="$GIT_TAG_DATE" GIT_COMMITTER_DATE="$GIT_TAG_DATE" git tag -a "$TAG" -m "yina $VERSION"

echo "==> Pushing tag"
git push "$REMOTE" "$TAG"

echo "==> Publishing release"
gh release create "$TAG" \
  --repo "$REPO" --verify-tag \
  --title "yina $VERSION" \
  --notes "yina $VERSION" \
  "$ARCHIVE" "$APPCAST"

echo "==> Publishing appcast to gh-pages"
"$SCRIPT_DIR/publish_appcast.sh" "$APPCAST" "$RELEASE_OUT" "$REMOTE"

echo
echo "Released yina $VERSION"
