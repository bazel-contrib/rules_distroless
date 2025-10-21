"normalization rules"

TAR_TOOLCHAIN_TYPE = "@tar.bzl//tar/toolchain:type"

def _apt_cursed_symlink(ctx):
    bsdtar = ctx.toolchains[TAR_TOOLCHAIN_TYPE]

    for (i, symlink_out) in enumerate(ctx.outputs.symlink_outs):
        ctx.actions.symlink(
            output = symlink_out,
            target_file = ctx.files.symlinks[i],
        )

    for (i, symlink_out) in enumerate(ctx.outputs.self_symlink_outs):
        ctx.actions.symlink(
            output = symlink_out,
            target_file = ctx.outputs.outs[ctx.attr.self_symlink_output_indices[i]],
        )

    if len(ctx.outputs.outs):
        fout = ctx.outputs.outs[0]
        output = fout.path[:fout.path.find(fout.owner.repo_name) + len(fout.owner.repo_name)]
        args = ctx.actions.args()
        args.add("-xf")
        args.add_all(ctx.files.srcs)
        args.add("-C")
        args.add(output)
        args.add_all(
            ctx.outputs.outs,
            map_each = lambda src: src.short_path[len(src.owner.repo_name) + 4:],
            allow_closure = True,
        )
        ctx.actions.run(
            executable = bsdtar.tarinfo.binary,
            inputs = ctx.files.srcs,
            outputs = ctx.outputs.outs,
            arguments = [args],
            mnemonic = "Unpack",
            toolchain = TAR_TOOLCHAIN_TYPE,
        )

    return DefaultInfo(
        files = depset(
            ctx.outputs.outs +
            ctx.outputs.symlink_outs +
            ctx.outputs.self_symlink_outs,
        ),
    )

deb_cc_export = rule(
    implementation = _apt_cursed_symlink,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "symlinks": attr.label_list(allow_files = True),
        "symlink_outs": attr.output_list(),
        "self_symlink_outs": attr.output_list(),
        "self_symlink_output_indices": attr.int_list(),
        "deps": attr.label_list(allow_files = True),
        "outs": attr.output_list(),
    },
    toolchains = [
        TAR_TOOLCHAIN_TYPE,
    ],
)

# # buildifier: disable=function-docstring-args
# def deb_cc_export(name, src, outs, **kwargs):
#     """Private. DO NOT USE."""
#     if len(outs) == 0:
#         native.filegroup(name = name, srcs = [], **kwargs)
#         return
#     toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"]

#     cmd = """
# $(BSDTAR_BIN) -xf "$<" -C $(RULEDIR) {}  \
# """.format(
#         " ".join(outs),
#     )
#     native.genrule(
#         name = name,
#         srcs = [src],
#         outs = [out.removeprefix("./") for out in outs],
#         cmd = cmd,
#         toolchains = toolchains,
#         output_to_bindir = True,
#         **kwargs
#     )
