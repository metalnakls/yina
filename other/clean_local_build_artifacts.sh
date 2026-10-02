#!/bin/bash

set -euo pipefail
shopt -s nullglob

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BACKUP_DIR="$(cd "$REPO_DIR/.." && pwd)/.build-backups"

apply=false

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--apply" ]]; }; then
  echo "usage: $0 [--apply]" >&2
  exit 64
fi

if (( $# == 1 )); then
  apply=true
fi

declare -a candidates=()

for path in \
  "$REPO_DIR"/DerivedData-* \
  "$REPO_DIR"/.scratch \
  "$BACKUP_DIR"/YINA-before-*.app \
  /private/tmp/yina-* \
  /private/tmp/YINA-before-*.app; do
  [[ -e "$path" ]] || continue
  git_root="$(/usr/bin/git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ "$git_root" == "$path" ]]; then
    continue
  fi
  candidates+=("$path")
done

if (( ${#candidates[@]} == 0 )); then
  echo "No disposable YINA build artifacts found."
  exit 0
fi

printf '%s\n' "Disposable YINA build artifacts:"
printf '  %s\n' "${candidates[@]}"

if [[ "$apply" != true ]]; then
  echo "Dry run only. Re-run with --apply after an explicit cleanup request."
  exit 0
fi

for path in "${candidates[@]}"; do
  rm -rf -- "$path"
done

echo "Removed ${#candidates[@]} disposable YINA build artifact(s)."
