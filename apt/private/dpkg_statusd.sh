#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly bsdtar="$1"
readonly out="$2"
readonly control_path="$3"
readonly package_name="$4"
readonly awk="$5"
shift 5

include=(--include "^./control$" --include "^./md5sums$")

tmp=$(mktemp -d)
"$bsdtar" -xf "$control_path" "${include[@]}" -C "$tmp"

"$bsdtar" -cf - $@ --format=mtree "${include[@]}" --options '!gname,!uname,!sha1,!nlink,!time' "@$control_path" | \
"${awk}" -v pkg="$package_name" '{ 
    if ($1=="#mtree") {
        print $1; next
    };
    # strip leading ./ prefix
    sub(/^\.?\//, "", $1);

    if ($1 ~ /^control/) {
        $1 = "./var/lib/dpkg/status.d/" pkg " contents=./" $1; 
    } else if ($1 ~ /^md5sums/) {
        $1 = "./var/lib/dpkg/status.d/" pkg ".md5sums contents=./" $1; 
    }
    print $0
}' | "$bsdtar" $@ -cf "$out" -C "$tmp/" @-
