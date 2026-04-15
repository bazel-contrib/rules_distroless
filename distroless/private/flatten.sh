#!/usr/bin/env bash
set -o pipefail -o errexit

bsdtar="$1";
deduplicate="$2";
readonly awk="$3"
readonly coreutils="$4"
shift 4;

# Deduplication requested, use this complex pipeline to deduplicate.
if [[ "$deduplicate" == "True" ]]; then

    mtree=$($coreutils mktemp)

    # List files in all archives and append to single column mtree.
    for arg in "$@"; do
        if [[ "$arg" == "@"* ]]; then
            "$bsdtar" -tf "${arg:1}" >> "$mtree"
        fi
    done

    # There not a lot happening here but there is still too many implicit knowledge.
    #
    # When we run bsdtar, we ask for it to prompt every entry, in the same order we created above, the mtree.
    # See: https://github.com/libarchive/libarchive/blob/f745a848d7a81758cd9fcd49d7fd45caeebe1c3d/tar/write.c#L683
    #
    # For every prompt, therefore entry, we have write 31 bytes of data, one of which has to be either 'Y' or 'N'.
    # And the reason for it is that since we are not TTY and pretending to be one, we can't interleave write calls
    # so we have to interleave it by filling up the buffer with 31 bytes of 'Y' or 'N'.
    # See: https://github.com/libarchive/libarchive/blob/f745a848d7a81758cd9fcd49d7fd45caeebe1c3d/tar/util.c#L240
    # See: https://github.com/libarchive/libarchive/blob/f745a848d7a81758cd9fcd49d7fd45caeebe1c3d/tar/util.c#L216
    #
    # To match the extraction behavior of tar itself, we want to preserve only the final occurrence of each file
    # and directory in the archive. To do this, we iterate over all the entries twice. The first pass computes the
    # number of occurrences of each path, and the second pass determines whether each entry is the final (or only)
    # occurrence of that path.

    $bsdtar --confirmation "$@" 2< <("${awk}" '
    function normalize(p) {
        # Strip trailing "/" and add leading "./" so that "./etc/" and "etc/" are treated as the same path.
        sub(/\/$/, "", p)
        if (p !~ /^\.\// && p !~ /^\//) {
            p = "./" p
        }
        return p
    }
    {
        key = normalize($1)
        count[key]++
        files[NR] = $1
        keys[NR] = key
    }
    END {
        ORS=""
        for (i=1; i<=NR; i++) {
            seen[keys[i]]++
            keep="n"
            if (count[keys[i]] == seen[keys[i]]) {
                keep="y"
            }
            for (j=0; j<31; j++) print keep
            fflush()
        }
    }' "$mtree")
    rm "$mtree"
else
    # No deduplication, business as usual
    $bsdtar "$@"
fi
