"Unpack tar archives into a tree artifact."

# buildifier: disable=bzl-visibility
load("//distroless/private:tar.bzl", "tar_lib")

_DOC = """Extract tar archives into a single sysroot directory tree."""

def _apt_sysroot_impl(ctx):
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]
    output = ctx.actions.declare_directory(ctx.attr.name)

    args = ctx.actions.args()
    args.add(bsdtar.tarinfo.binary)
    args.add(output.path)
    args.add_all(ctx.files.tars)

    ctx.actions.run(
        executable = ctx.executable._sysroot_sh,
        inputs = ctx.files.tars,
        outputs = [output],
        tools = bsdtar.default.files,
        arguments = [args],
        mnemonic = "AptSysroot",
        progress_message = "Creating apt sysroot %{label}",
    )

    return [DefaultInfo(files = depset([output]))]

apt_sysroot = rule(
    doc = _DOC,
    attrs = {
        "tars": attr.label_list(
            allow_files = tar_lib.common.accepted_tar_extensions,
            mandatory = True,
            allow_empty = False,
            doc = "List of tar archives to extract into a sysroot directory.",
        ),
        "_sysroot_sh": attr.label(
            default = ":sysroot.sh",
            executable = True,
            cfg = "exec",
            allow_single_file = True,
        ),
    },
    implementation = _apt_sysroot_impl,
    toolchains = [tar_lib.TOOLCHAIN_TYPE],
)
