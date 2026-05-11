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

        # Find the target File object in outs, self_symlink outputs, or foreign_symlink outputs
        target_file = None
        for f in ctx.outputs.outs:
            if f.short_path[len(f.owner.repo_name) + 4:] == target_path:
                target_file = f
                break
        if target_file == None:
            for j, other_path in enumerate(self_symlink_keys):
                if other_path == target_path:
                    target_file = ctx.outputs.symlink_outs[foreign_symlink_count + j]
                    break
        if target_file == None:
            for j in range(foreign_symlink_count):
                f = ctx.outputs.symlink_outs[j]
                if f.short_path[len(f.owner.repo_name) + 4:] == target_path:
                    target_file = f
                    break
        if target_file == None:
            for f in ctx.outputs.linkscript_outs:
                if f.short_path[len(f.owner.repo_name) + 4:] == target_path:
                    target_file = f
                    break
        if target_file != None:
            ctx.actions.symlink(
                output = ctx.outputs.symlink_outs[foreign_symlink_count + i],
                target_file = target_file,
            )

    # Generate linkscript files with rewritten content
    # Write a template file with $$BINDIR placeholder, then replace at execution
    # time with the absolute path (pwd + bin_dir.path) since analysis-time paths
    # are relative.
    for ls_out in ctx.outputs.linkscript_outs:
        ls_path = ls_out.short_path[len(ls_out.owner.repo_name) + 4:]
        content = ctx.attr.linkscripts.get(ls_path, "")

        # Write template with placeholder to an intermediate file
        template_file = ctx.actions.declare_file(ls_out.basename + ".tpl", sibling = ls_out)
        ctx.actions.write(
            output = template_file,
            content = content,
        )
        ctx.actions.run_shell(
            inputs = [template_file] + ctx.files.linkscript_deps,
            outputs = [ls_out],
            command = 'sed "s|\\$\\$BINDIR|$(pwd)/{bindir}|g" "{tpl}" > "{out}"'.format(
                bindir = ctx.bin_dir.path,
                tpl = template_file.path,
                out = ls_out.path,
            ),
            mnemonic = "LinkScript",
            execution_requirements = {"no-sandbox": "1"},
        )

    if len(ctx.outputs.outs):
        fout = ctx.outputs.outs[0]
        output_base = fout.path[:fout.path.find(fout.owner.repo_name) + len(fout.owner.repo_name)]
        args = ctx.actions.args()
        args.add_all(ctx.files.srcs)
        args.add(output_base)
        args.add_all(
            ctx.outputs.outs,
            map_each = lambda src: src.short_path[len(src.owner.repo_name) + 4:],
            allow_closure = True,
        )
        ctx.actions.run_shell(
            outputs = ctx.outputs.outs,
            inputs = ctx.files.srcs,
            tools = [bsdtar.tarinfo.binary],
            command = """
                "{tar}" -xf $1 -C $2 "${{@:3}}"
            """.format(
                tar = bsdtar.tarinfo.binary.path,
            ),
            arguments = [args],
            mnemonic = "Unpack",
            toolchain = TAR_TOOLCHAIN_TYPE,
        )

    return DefaultInfo(
        files = depset(
            ctx.outputs.outs +
            ctx.outputs.symlink_outs +
            ctx.outputs.linkscript_outs +
            ctx.files.foreign_symlinks +
            ctx.files.linkscript_deps,
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
        # mapping of linkscript path -> rewritten content
        "linkscripts": attr.string_dict(),
        "linkscript_outs": attr.output_list(),
        # external files referenced by linkscripts
        "linkscript_deps": attr.label_list(allow_files = True),
    },
    toolchains = [
        TAR_TOOLCHAIN_TYPE,
    ],
)
