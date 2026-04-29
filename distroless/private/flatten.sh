#!/usr/bin/env bash
set -o pipefail -o errexit

readonly bsdtar="$1"
readonly deduplicate="$2"
readonly coreutils="$3"
shift 3

function repeat_confirmation () {
    local answer="$1"

    for ((j = 0; j < 31; j++)); do
        printf '%s' "$answer"
    done
}

if [[ "$deduplicate" != "True" ]]; then
    "$bsdtar" "$@"
    exit 0
fi

declare -a paths=()
for arg in "$@"; do
    [[ "$arg" == @* ]] || continue

    while IFS= read -r path; do
        paths+=("$path")
    done < <("$bsdtar" -tf "${arg:1}")
done

# bsdtar prompts once per entry, in archive order.
# Each response must be repeated 31 times, and we keep only the final occurrence of each path.
# Pipe through cat so responses are forwarded promptly as bsdtar asks for them.
# See: https://github.com/libarchive/libarchive/blob/f745a848d7a81758cd9fcd49d7fd45caeebe1c3d/tar/write.c#L683
# See: https://github.com/libarchive/libarchive/blob/f745a848d7a81758cd9fcd49d7fd45caeebe1c3d/tar/util.c#L240
# See: https://github.com/libarchive/libarchive/blob/f745a848d7a81758cd9fcd49d7fd45caeebe1c3d/tar/util.c#L216
declare -a keep=()
declare -A seen=()
for ((i = ${#paths[@]} - 1; i >= 0; i--)); do
    path="${paths[$i]}"
    if [[ -n "${seen["$path"]+set}" ]]; then
        keep[$i]="n"
    else
        seen["$path"]=1
        keep[$i]="y"
    fi
done

readonly answers_file=$(mktemp)
trap 'rm -f "$answers_file"' EXIT

for ((i = 0; i < ${#keep[@]}; i++)); do
    repeat_confirmation "${keep[$i]}"
done > "$answers_file"

"$bsdtar" --confirmation "$@" 2< "$answers_file"
