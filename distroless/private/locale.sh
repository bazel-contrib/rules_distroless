#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly bsdtar="$1"
readonly out="$2"
readonly package_path="$3"
readonly time="$4"
readonly coreutils="$5"
shift 5

# TODO: there must be a better way to manipulate tars!
# "$bsdtar" -cf  $out --posix --no-same-owner --options="" $@ "@$package_path"
# "$bsdtar" -cf to.mtree $@ --format=mtree --options '!gname,!uname,!sha1,!nlink' "@$package_path"
# "$bsdtar" --older "0" -Uf $out @to.mtree

tmp=$($coreutils mktemp -d)
"$bsdtar" -xf "$package_path" $@ -C "$tmp"
"$bsdtar" -cf - $@ --format=mtree --options '!gname,!uname,!sha1,!nlink,!time' "@$package_path" |
    while IFS= read -r line; do
        printf '%s time=%s\n' "$line" "$time"
    done |
    "$bsdtar" --gzip --options 'gzip:!timestamp' -cf "$out" -C "$tmp/" @-
