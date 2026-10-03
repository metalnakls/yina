#!/bin/bash

#
#  publish_appcast.sh
#  yina
#
#  Publishes the Sparkle appcast and the signed update archive to the gh-pages
#  branch that GitHub Pages serves, so SUFeedURL resolves to a current feed.
#
#  Usage:
#    other/publish_appcast.sh <appcast.xml> <archive-dir> [remote]
#

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <appcast.xml> <archive-dir> [remote]" >&2
  exit 64
fi

APPCAST="$1"
ARCHIVE_DIR="$2"
REMOTE="${3:-yina}"
BRANCH=gh-pages
PAGES_DIR=gh-pages-publish

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

if [ ! -f "$APPCAST" ]; then
  echo "appcast not found: $APPCAST" >&2
  exit 66
fi

# Never destroy an existing publish directory from a previous failed run.
rm -rf "$PAGES_DIR"

git fetch "$REMOTE" "$BRANCH" --depth 1 2>/dev/null || true

if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 \
   || git rev-parse --verify "$REMOTE/$BRANCH" >/dev/null 2>&1; then
  git worktree add --detach "$PAGES_DIR" "origin/$BRANCH" 2>/dev/null \
    || git worktree add --detach "$PAGES_DIR" "$REMOTE/$BRANCH"
else
  git worktree add --detach "$PAGES_DIR" >/dev/null
  git -C "$PAGES_DIR" checkout --orphan "$BRANCH"
  git -C "$PAGES_DIR" rm -rf . >/dev/null 2>&1 || true
  mkdir -p "$PAGES_DIR"
fi

# Keep prior releases so an older client can still fetch the version it has.
mkdir -p "$PAGES_DIR/releases"
cp "$ARCHIVE_DIR"/*.zip "$PAGES_DIR/releases/" 2>/dev/null || true

if [ ! -f "$PAGES_DIR/index.html" ]; then
  cat > "$PAGES_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>yina</title></head>
<body><p>yina update feed. See <a href="appcast.xml">appcast.xml</a>.</p></body>
</html>
HTML
fi

cp "$APPCAST" "$PAGES_DIR/appcast.xml"

git -C "$PAGES_DIR" add -A
if git -C "$PAGES_DIR" diff --cached --quiet; then
  echo "appcast unchanged; nothing to publish"
else
  git -C "$PAGES_DIR" commit -m "Publish appcast $(basename "$APPCAST")"
  git -C "$PAGES_DIR" push "$REMOTE" "$BRANCH"
  echo "published $BRANCH"
fi

git worktree remove --force "$PAGES_DIR"
rm -rf "$PAGES_DIR"
