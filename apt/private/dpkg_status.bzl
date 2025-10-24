"dpkg_status"

# buildifier: disable=bzl-visibility
load("//distroless/private:tar.bzl", "tar_lib")

_DOC = """TODO: docs"""

def _dpkg_status_impl(ctx):
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]

    output = ctx.actions.declare_file(ctx.attr.name + ".tar")

    args = ctx.actions.args()
    args.add(bsdtar.tarinfo.binary)
    args.add(output)
    args.add(ctx.executable._gawk.path)
    args.add_all(ctx.files.controls)

    ctx.actions.run(
        executable = ctx.executable._dpkg_status_sh,
        inputs = ctx.files.controls,
        outputs = [output],
        tools = [bsdtar.default.files, ctx.executable._gawk],
        arguments = [args],
    )

    return [
        DefaultInfo(files = depset([output])),
    ]

dpkg_status = rule(
    doc = _DOC,
    attrs = {
        "_dpkg_status_sh": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = ":dpkg_status.sh",
        ),
        "controls": attr.label_list(
            allow_files = [".tar.zst", ".tar.xz", ".tar.gz", ".tar"],
            mandatory = True,
        ),
        "_gawk": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = "@gawk//:gawk",
        ),
    },
    implementation = _dpkg_status_impl,
    toolchains = [tar_lib.TOOLCHAIN_TYPE],
)
