#!/usr/bin/env bash
set -euo pipefail

bsdtar="$1"
out="$2"
shift 2

mkdir -p "$out"

for tar in "$@"; do
  "$bsdtar" -xf "$tar" -C "$out"
done

# Bazel tree artifacts cannot contain dangling symlinks.
while IFS= read -r -d '' link; do
  if [[ ! -e "$link" ]]; then
    rm -f "$link"
  fi
done < <(find "$out" -type l -print0)
