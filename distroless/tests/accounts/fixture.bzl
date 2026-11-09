"""Small OCI layout fixtures built with declared Python and BSD tar tools."""

load("//distroless/private:tar.bzl", "tar_lib")

def _impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name)
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]
    args = ctx.actions.args()
    args.add("--output", output.path)
    args.add("--architecture", ctx.attr.architecture)
    args.add("--compression", ctx.attr.compression)
    args.add("--bsdtar", bsdtar.tarinfo.binary)
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        tools = bsdtar.default.files,
        outputs = [output],
        mnemonic = "AccountBaseFixture",
    )
    return [DefaultInfo(files = depset([output]))]

account_base_fixture = rule(
    implementation = _impl,
    attrs = {
        "architecture": attr.string(mandatory = True),
        "compression": attr.string(default = "none", values = ["none", "gzip", "xz", "zstd"]),
        "_tool": attr.label(default = Label(":fixture"), executable = True, cfg = "exec"),
    },
    toolchains = [tar_lib.TOOLCHAIN_TYPE],
)
