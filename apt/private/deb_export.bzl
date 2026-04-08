"normalization rules"

load("@aspect_bazel_lib//lib:tar.bzl", tar = "tar_lib")

TAR_TOOLCHAIN_TYPE = tar.toolchain_type

def _deb_export_impl(ctx):
    bsdtar = ctx.toolchains[TAR_TOOLCHAIN_TYPE]

    foreign_symlinks = {
        symlink: json.decode(indices_json)
        for (symlink, indices_json) in ctx.attr.foreign_symlinks.items()
    }

    # foreign_symlinks maps label -> index string (reversed for Bazel 7.0.0 compatibility)
    for (target, indices_json) in ctx.attr.foreign_symlinks.items():
        indices = json.decode(indices_json)
        for i in indices:
            ctx.actions.symlink(
                output = ctx.outputs.symlink_outs[i],
                # grossly inefficient
                target_file = target[DefaultInfo].files.to_list()[0],
            )

    # self_symlinks maps symlink path -> target path (both within this package)
    # symlink_outs contains foreign symlink outputs first, then self symlink outputs
    foreign_symlink_count = 0
    for v in foreign_symlinks.values():
        foreign_symlink_count += len(v)
    self_symlink_keys = list(ctx.attr.self_symlinks.keys())
    for i, symlink_path in enumerate(self_symlink_keys):
        target_path = ctx.attr.self_symlinks[symlink_path]

        # Find the target File object in outs
        target_file = None
        for f in ctx.outputs.outs:
            if f.short_path[len(f.owner.repo_name) + 4:] == target_path:
                target_file = f
                break
        if target_file != None:
            ctx.actions.symlink(
                output = ctx.outputs.symlink_outs[foreign_symlink_count + i],
                target_file = target_file,
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
            ctx.files.foreign_symlinks,
        ),
    )

deb_export = rule(
    implementation = _deb_export_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        # mapping of foreign label -> symlink_outs index (label_keyed for Bazel 7.0 compat)
        "foreign_symlinks": attr.label_keyed_string_dict(allow_files = True),
        # mapping of symlink path -> target path (both within this package)
        "self_symlinks": attr.string_dict(),
        "symlink_outs": attr.output_list(),
        "outs": attr.output_list(),
    },
    toolchains = [
        TAR_TOOLCHAIN_TYPE,
    ],
)
