def _apt_cursed_symlink(ctx):
    own_path = ctx.attr.own_path.removeprefix(".")
    own_dirname = own_path[:own_path.rfind("/") + 1]
    candidate_full_path = own_dirname + ctx.attr.candidate_path

    found = None

    for file in ctx.files.candidates:
        if file.path.endswith(candidate_full_path):
            found = file
            break

    if not found:
        fail("Failed to find the candidate so library. file an issue.")

    ctx.actions.symlink(
        output = ctx.outputs.out,
        target_file = file,
    )
    return DefaultInfo(
        files = depset([ctx.outputs.out]),
    )

apt_cursed_symlink = rule(
    implementation = _apt_cursed_symlink,
    attrs = {
        "candidates": attr.label_list(),
        "candidate_path": attr.string(),
        "own_path": attr.string(),
        "out": attr.output(),
    },
)
