"dpkg_statusd"

# buildifier: disable=bzl-visibility
load("//distroless/private:tar.bzl", "tar_lib")

_DOC = """TODO: docs"""

def _dpkg_statusd_impl(ctx):
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]

    ext = tar_lib.common.compression_to_extension[ctx.attr.compression] if ctx.attr.compression else ".tar"
    output = ctx.actions.declare_file(ctx.attr.name + ext)

    args = ctx.actions.args()
    args.add(bsdtar.tarinfo.binary)
    args.add(output)
    args.add(ctx.file.control)
    args.add(ctx.attr.package_name)
    args.add(ctx.executable._gawk.path)
    tar_lib.common.add_compression_args(ctx.attr.compression, args)

    ctx.actions.run(
        executable = ctx.executable._dpkg_statusd_sh,
        inputs = [ctx.file.control],
        outputs = [output],
        tools = [bsdtar.default.files, ctx.executable._gawk],
        arguments = [args],
    )

    return [
        DefaultInfo(files = depset([output])),
    ]

dpkg_statusd = rule(
    doc = _DOC,
    attrs = {
        "_dpkg_statusd_sh": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = ":dpkg_statusd.sh",
        ),
        "package_name": attr.string(mandatory = True),
        "control": attr.label(
            allow_single_file = [".tar.zst", ".tar.xz", ".tar.gz", ".tar"],
            mandatory = True,
        ),
        "compression": attr.string(
            doc = "Compress the archive file with a supported algorithm.",
            values = tar_lib.common.accepted_compression_types,
        ),
        "_gawk": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = "@gawk//:gawk",
        ),
    },
    implementation = _dpkg_statusd_impl,
    toolchains = [tar_lib.TOOLCHAIN_TYPE],
)
