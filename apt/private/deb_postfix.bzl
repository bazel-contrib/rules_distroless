"normalization rules"

_ZSTD = "@bazel_lib//lib:zstd_toolchain_type"

def _deb_layer_impl(ctx):
    src = ctx.file.src
    out = ctx.outputs.out
    if src.basename.endswith("data.tar.gz"):
        ctx.actions.symlink(output = out, target_file = src)
        return

    tc = ctx.toolchains[_ZSTD]
    if src.basename.endswith(("data.tar.xz", "data.tar.zst", "data.tar.lzma")):
        tar = ctx.actions.declare_file(ctx.label.name + ".tar")
        # With forced output to stdout zstd passes an uncompressed input
        # through unchanged. Keep that behavior when writing a file.
        ctx.actions.run(
            executable = tc.zstdinfo.binary,
            tools = tc.default.files,
            inputs = [src],
            outputs = [tar],
            arguments = ["--decompress", "--force", "--quiet", "--pass-through", src.path, "-o", tar.path],
            mnemonic = "DebDecompress",
            toolchain = _ZSTD,
        )
        src = tar
    elif not src.basename.endswith("data.tar"):
        fail("unsupported Debian data archive: %s" % src.basename)

    # gzip mode uses level 6 and omits the original filename and timestamp.
    ctx.actions.run(
        executable = tc.zstdinfo.binary,
        tools = tc.default.files,
        inputs = [src],
        outputs = [out],
        arguments = ["--force", "--quiet", "--format=gzip", "-6", src.path, "-o", out.path],
        mnemonic = "DebGzip",
        toolchain = _ZSTD,
    )

_deb_layer = rule(
    implementation = _deb_layer_impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "out": attr.output(mandatory = True),
    },
    toolchains = [_ZSTD],
)

# buildifier: disable=function-docstring-args
def deb_postfix(name, src, out, mergedusr = False, **kwargs):
    """Private. DO NOT USE."""
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
        # Bash process substitution feeds the keep/drop answers from awk to bsdtar.
        cmd = """\
            data_file="$<"
            layer="$@"
            $(BSDTAR_BIN) --confirmation --gzip --options 'gzip:!timestamp' -cf "$$layer" \
            -s "#^\\./bin/\\(.\\)#./usr/bin/\\1#" \
            -s "#^\\./sbin/\\(.\\)#./usr/sbin/\\1#" \
            -s "#^\\./lib/\\(.\\)#./usr/lib/\\1#" \
            -s "#^\\./lib32/\\(.\\)#./usr/lib32/\\1#" \
            -s "#^\\./lib64/\\(.\\)#./usr/lib64/\\1#" \
            -s "#^\\./libx32/\\(.\\)#./usr/libx32/\\1#" \
            "@$$data_file" 2< <(
                $(BSDTAR_BIN) -tvf "$$data_file" | $(location @ape//ape:awk) '{
                    ORS=""
                    keep="y"
                    if (substr($$1, 1, 1) == "d" && (\\
                            $$9 == "./bin/" ||\\
                            $$9 == "./sbin/" ||\\
                            $$9 == "./lib/" ||\\
                            $$9 == "./lib32/" ||\\
                            $$9 == "./lib64/" ||\\
                            $$9 == "./libx32/" \\
                        )) {
                        keep="n"
                    }
                    for (j=0; j<31; j++) print keep
                    fflush()
                }'
            )
        """
        native.genrule(
            name = name,
            srcs = [src],
            outs = [out],
            cmd = cmd,
            toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
            tools = ["@ape//ape:awk"],
            **kwargs
        )
        return

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
    # The zstd toolchain can decompress all formats except bzip2.
    #
    # The OCI image spec supports .tar and .tar compressed with gzip or zstd.
    # Bazel needs the output filename to be fixed in advance so we settle for
    # gzip compression.
    _deb_layer(name = name, src = src, out = out, **kwargs)
