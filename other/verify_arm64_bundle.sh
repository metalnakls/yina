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

FOUND_MACHO=false

verify_macho() {
  local path="$1"
  local architectures
  local build_info
  local minos

  architectures=$(lipo -archs "$path") || return 1
  if [[ "$architectures" != "arm64" ]]; then
    echo "Unsupported architectures (${architectures}): $path" >&2
    return 1
  fi

  build_info=$(xcrun vtool -show-build "$path") || return 1
  minos=$(printf '%s\n' "$build_info" | awk '$1 == "minos" { print $2; exit }')
  if [[ -z "$minos" ]]; then
    echo "Missing LC_BUILD_VERSION minimum: $path" >&2
    return 1
  fi
  if [[ ${minos%%.*} -lt 27 ]]; then
    echo "Deployment target ${minos} is below macOS 27: $path" >&2
    return 1
  fi
}

if [[ -f "$ROOT_PATH" ]] && file -b "$ROOT_PATH" | grep -q "Mach-O"; then
  FOUND_MACHO=true
  verify_macho "$ROOT_PATH"
elif [[ -d "$ROOT_PATH" ]]; then
  while IFS= read -r -d '' path; do
    if file -b "$path" | grep -q "Mach-O"; then
      FOUND_MACHO=true
      verify_macho "$path"
    fi
  done < <(find "$ROOT_PATH" -type f -print0)
fi

if [[ "$FOUND_MACHO" != true ]]; then
  echo "No Mach-O files found: $ROOT_PATH" >&2
  exit 1
fi

echo "Verified arm64-only macOS 27 Mach-O files in $ROOT_PATH"
