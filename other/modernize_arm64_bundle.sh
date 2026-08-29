#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <bundle-or-binary>" >&2
  exit 2
fi

ROOT_PATH=$1
if [[ ! -e "$ROOT_PATH" ]]; then
  echo "Path does not exist: $ROOT_PATH" >&2
  exit 1
fi

modernize_macho() {
  local path="$1"
  local architectures
  local mode
  local thinned_path
  local modern_path

  architectures=$(lipo -archs "$path") || return 1
  mode=$(stat -f '%Lp' "$path") || return 1

  if [[ "$architectures" != "arm64" ]]; then
    if [[ " $architectures " != *" arm64 "* ]]; then
      echo "Mach-O has no arm64 slice: $path" >&2
      return 1
    fi
    thinned_path=$(mktemp "${path}.arm64.XXXXXX") || return 1
    lipo "$path" -thin arm64 -output "$thinned_path"
    chmod "$mode" "$thinned_path"
    mv "$thinned_path" "$path"
  fi

  modern_path=$(mktemp "${path}.macos27.XXXXXX") || return 1
  xcrun vtool -set-build-version macos 27.0 27.0 -replace -output "$modern_path" "$path"
  chmod "$mode" "$modern_path"
  mv "$modern_path" "$path"
}

if [[ -f "$ROOT_PATH" ]] && file -b "$ROOT_PATH" | grep -q "Mach-O"; then
  modernize_macho "$ROOT_PATH"
elif [[ -d "$ROOT_PATH" ]]; then
  while IFS= read -r -d '' path; do
    if file -b "$path" | grep -q "Mach-O"; then
      modernize_macho "$path"
    fi
  done < <(find "$ROOT_PATH" -type f -print0)
else
  echo "No Mach-O files found: $ROOT_PATH" >&2
  exit 1
fi
