#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly bsdtar="$1"
readonly out="$2"
readonly control_path="$3"
readonly package_name="$4"
readonly coreutils="$5"
shift 5

include=(--include "^./control$" --include "^./md5sums$")

tmp=$($coreutils mktemp -d)
"$bsdtar" -xf "$control_path" "${include[@]}" -C "$tmp"

"$bsdtar" -cf - $@ --format=mtree "${include[@]}" --options '!gname,!uname,!sha1,!nlink,!time' "@$control_path" | \
while IFS= read -r line; do
    if [[ "$line" == "#mtree" ]]; then
        printf '%s\n' "$line"
        continue
    fi

    path="${line%% *}"
    rest="${line#"$path"}"
    stripped="${path#./}"
    stripped="${stripped#/}"

    if [[ "$stripped" == control* ]]; then
        new_path="./var/lib/dpkg/status.d/$package_name"
    elif [[ "$stripped" == md5sums* ]]; then
        new_path="./var/lib/dpkg/status.d/$package_name.md5sums"
    else
        new_path="$path"
    fi

    printf '%s contents=./%s%s\n' "$new_path" "$stripped" "$rest"
done | "$bsdtar" $@ -cf "$out" -C "$tmp/" @-
