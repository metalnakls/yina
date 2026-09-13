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
  "$REPO_DIR"/.scratch/IINA-*.app \
  "$BACKUP_DIR"/IINA-before-*.app \
  /private/tmp/iina-* \
  /private/tmp/IINA-before-*.app; do
  [[ -e "$path" ]] || continue
  candidates+=("$path")
done

if (( ${#candidates[@]} == 0 )); then
  echo "No disposable IINA build artifacts found."
  exit 0
fi

printf '%s\n' "Disposable IINA build artifacts:"
printf '  %s\n' "${candidates[@]}"

if [[ "$apply" != true ]]; then
  echo "Dry run only. Re-run with --apply after an explicit cleanup request."
  exit 0
fi

for path in "${candidates[@]}"; do
  rm -rf -- "$path"
done

echo "Removed ${#candidates[@]} disposable IINA build artifact(s)."
