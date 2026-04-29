"normalization rules"

load(":util.bzl", "util")

# buildifier: disable=function-docstring-args
def deb_postfix(name, srcs, outs, mergedusr = False, **kwargs):
    """Private. DO NOT USE."""
    apply = """
    case "$$data_file" in
        *data.tar.gz)
            mv "$$data_file" "$$layer"
        ;;
        *data.tar)
            (exec -a gzip $(ZSTD_BIN) -n) < "$$data_file" > "$$layer"
        ;;
        *data.tar.xz|*data.tar.zst|*data.tar.lzma)
            $(ZSTD_BIN) --force --decompress --stdout "$$data_file" |
            (exec -a gzip $(ZSTD_BIN) -n) > "$$layer"
        ;;
        *)
            echo "ERROR: data file not supported: $$data_file"
            exit 1
        ;;
    esac
"""
    toolchains = ["@zstd_toolchains//:resolved_toolchain"]

    # If mergedusr, then rewrite paths to hoist bins/libs from / of the fs to /usr counterpart.
    # Be careful with this option as it assumes that /usr/ is mounted as one filesystem.
    # This implementation does not merge /usr/sbin and /usr/bin as prescribed by debian
    # Read more:
    # https://wiki.gentoo.org/wiki/Merge-usr
    # https://salsa.debian.org/md/usrmerge/raw/master/debian/README.Debian
    # https://www.freedesktop.org/wiki/Software/systemd/TheCaseForTheUsrMerge/
    # Mapping taken from https://github.com/floppym/merge-usr/blob/15dd02207bdee7ca6720d7024e8c0ffdc166ed23/merge-usr#L17-L25
    # https://salsa.debian.org/md/usrmerge/-/tree/master/debian?ref_type=heads
    if mergedusr:
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"]
        apply = util.mergedusr_rewrite_script("$(BSDTAR_BIN)", dollar = "$$")

    native.genrule(
        name = name,
        srcs = srcs,
        outs = outs,
        cmd = """
        # Per the dpkg-dev man page:
        # https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html
        #
        # Debian data.tar files can be:
        #  - .tar uncompressed, supported since dpkg 1.10.24
        #  - .tar compressed with
        #    *  gzip: .gz
        #    * bzip2: .bz2, supported since dpkg 1.10.24
        #    *  lzma: .lzma, supported since dpkg 1.13.25
        #    *    xz: .xz, supported since dpkg 1.15.6
        #    *  zstd: .zst, supported since dpkg 1.21.18
        #
        # ZSTD_BIN can decompress all formats except bzip2
        #
        # The OCI image spec supports .tar and .tar compressed with gzip or zstd.
        # Bazel needs the output filename to be fixed in advanced so we settle for
        # gzip compression.

        data_file="$<"
        layer="$@"

        %s
        """ % apply,
        toolchains = toolchains,
        **kwargs
    )
