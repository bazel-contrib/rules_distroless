#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly bsdtar="$1"
readonly out="$2"
readonly coreutils="$3"
shift 3

tmp_out=$("$coreutils" mktemp)

for deb; do
    {
        read -r first_line
        printf '%s\n' "$first_line" "Status: install ok installed"
        cat
    } < <("$bsdtar" -xf "$deb" --to-stdout ./control) >> "$tmp_out"
    printf '\n' >> "$tmp_out"
done

echo "#mtree
./var/lib/dpkg/status type=file uid=0 gid=0 mode=0644 time=1672560000 contents=$tmp_out
" | "$bsdtar" -cf "$out" "@-"

"$coreutils" rm "$tmp_out"
