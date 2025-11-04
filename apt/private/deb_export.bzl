"normalization rules"

TAR_TOOLCHAIN_TYPE = "@tar.bzl//tar/toolchain:type"

def _deb_export_impl(ctx):
    bsdtar = ctx.toolchains[TAR_TOOLCHAIN_TYPE]

    for (i, target) in ctx.attr.foreign_symlinks.items():
        i = int(i)
        ctx.actions.symlink(
            output = ctx.outputs.symlink_outs[i],
            # grossly inefficient
            target_file = target[DefaultInfo].files.to_list()[0],
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
            # the archive may contain symlinks that point to symlinks that reference
            # files from other packages, therefore symlink_outs must be present in the
            # sandbox for Bazel to succesfully track them.
            inputs = ctx.files.srcs + ctx.outputs.symlink_outs,
            outputs = ctx.outputs.outs,
            arguments = [args],
            mnemonic = "Unpack",
            toolchain = TAR_TOOLCHAIN_TYPE,
        )

    return DefaultInfo(
        files = depset(
            ctx.outputs.outs +
            ctx.outputs.symlink_outs +
            ctx.files.foreign_symlinks,
        ),
    )

deb_export = rule(
    implementation = _deb_export_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        # mapping of symlink_outs indice to a foreign label
        "foreign_symlinks": attr.string_keyed_label_dict(allow_files = True),
        "symlink_outs": attr.output_list(),
        "outs": attr.output_list(),
    },
    toolchains = [
        TAR_TOOLCHAIN_TYPE,
    ],
)
