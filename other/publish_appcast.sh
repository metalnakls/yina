#!/bin/bash
# Publish the download page and Sparkle feed together, preserving prior files.
# Usage: other/publish_appcast.sh <appcast.xml> <archive-dir> [remote]
set -euo pipefail
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <appcast.xml> <archive-dir> [remote]" >&2
  exit 64
fi
APPCAST="$1"
ARCHIVE_DIR="$2"
REMOTE="${3:-yina}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/even-git-time.sh"
APPCAST="$(cd "$(dirname "$APPCAST")" && pwd)/$(basename "$APPCAST")"
test -f "$APPCAST"
test -d "$ARCHIVE_DIR"
cd "$REPO_DIR"
# Fetch must succeed: a network failure must never create a replacement history.
git fetch "$REMOTE" gh-pages
PUBLISH_ROOT="$(mktemp -d /tmp/yina-pages.XXXXXX)"
PAGES_DIR="$PUBLISH_ROOT/checkout"
cleanup() {
  git -C "$REPO_DIR" worktree remove "$PAGES_DIR" >/dev/null 2>&1 || true
  rmdir "$PUBLISH_ROOT" 2>/dev/null || true
}
trap cleanup EXIT
git worktree add --detach "$PAGES_DIR" "$REMOTE/gh-pages"
cp "$REPO_DIR/site/"* "$PAGES_DIR/"
cp "$APPCAST" "$PAGES_DIR/appcast.xml"
mkdir -p "$PAGES_DIR/.github/workflows"
cp "$REPO_DIR/.github/workflows/pages.yml" "$PAGES_DIR/.github/workflows/pages.yml"
touch "$PAGES_DIR/.nojekyll"
git -C "$PAGES_DIR" add index.html favicon.png appcast.xml .nojekyll .github/workflows/pages.yml
if ! git -C "$PAGES_DIR" diff --cached --quiet; then
  wait_for_even_git_minute
  GIT_COMMIT_DATE="$(nearest_even_git_timestamp)"
  GIT_AUTHOR_DATE="$GIT_COMMIT_DATE" GIT_COMMITTER_DATE="$GIT_COMMIT_DATE" git -C "$PAGES_DIR" commit -m pages
  wait_for_even_git_minute
  git -C "$PAGES_DIR" push "$REMOTE" HEAD:refs/heads/gh-pages
fi
