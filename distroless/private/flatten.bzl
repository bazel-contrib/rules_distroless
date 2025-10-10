"flatten"

load(":tar.bzl", "tar_lib")

_DOC = """Flatten multiple archives into single archive."""

def _flatten_impl(ctx):
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]

    ext = tar_lib.common.compression_to_extension[ctx.attr.compress] if ctx.attr.compress else ".tar"
    output = ctx.actions.declare_file(ctx.attr.name + ext)

    args = ctx.actions.args()
    args.add(bsdtar.tarinfo.binary)
    args.add(str(ctx.attr.deduplicate))
    args.add(ctx.executable._gawk.path)
    args.add_all(tar_lib.DEFAULT_ARGS)
    args.add("--create")
    tar_lib.common.add_compression_args(ctx.attr.compress, args)
    args.add("--file", output)
    args.add_all(ctx.files.tars, format_each = "@%s")

    ctx.actions.run(
        executable = ctx.executable._flatten_sh,
        inputs = ctx.files.tars,
        outputs = [output],
        tools = [bsdtar.default.files, ctx.executable._gawk],
        arguments = [args],
        mnemonic = "Flatten",
        progress_message = "Flattening %{label}",
    )

    return [
        DefaultInfo(files = depset([output])),
    ]

flatten = rule(
    doc = _DOC,
    attrs = {
        "tars": attr.label_list(
            allow_files = tar_lib.common.accepted_tar_extensions,
            mandatory = True,
            allow_empty = False,
            doc = "List of tars to flatten",
        ),
        "deduplicate": attr.bool(doc = """\
EXPERIMENTAL: We may change or remove it without a notice.

Remove duplicate entries from the archives after flattening.
Deduplication is performed only for directories.
        """, default = False),
        "compress": attr.string(
            doc = "Compress the archive file with a supported algorithm.",
            values = tar_lib.common.accepted_compression_types,
        ),
        "_flatten_sh": attr.label(default = "//distroless/private:flatten.sh", executable = True, cfg = "exec", allow_single_file = True),
        "_gawk": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = "@gawk//:gawk",
        ),
    },
    implementation = _flatten_impl,
    toolchains = [tar_lib.TOOLCHAIN_TYPE],
)
