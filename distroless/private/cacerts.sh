#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly bsdtar="$1"
readonly package_path="$2"
readonly cacerts_out="$3"
readonly copyright_out="$4"
readonly coreutils="$5"
readonly tmp="$($coreutils mktemp -d)"

"$bsdtar" -xf "$package_path" -C "$tmp" ./usr/share/ca-certificates ./usr/share/doc/ca-certificates/copyright

$coreutils mv "$tmp/usr/share/doc/ca-certificates/copyright" "$copyright_out"

function add_cert () {
    local dir="$1"

    if test -d "${dir}"; then
        for cert in "${dir}"/*; do
            if test -d "${cert}"; then
                add_cert "${cert}"
                continue
            fi
            while IFS= read -r IN; do
                printf "%s\n" "${IN}" >> $cacerts_out
            done <"${cert}"
        done
    fi
}

add_cert "$tmp/usr/share/ca-certificates"
$coreutils rm -rf "$tmp"
