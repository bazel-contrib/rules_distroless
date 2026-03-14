"cc_deb_library"

def _cc_deb_library_impl(ctx):
    system_include_path = ctx.bin_dir.path + "/" + ctx.label.workspace_root + "/usr/include"

    compilation_context = cc_common.create_compilation_context(
        headers = depset(ctx.files.hdrs + ctx.files.additional_compiler_inputs),
        system_includes = depset([system_include_path]),
    )

    expanded_linkopts = [ctx.expand_make_variables("linkopts", opt, {}) for opt in ctx.attr.linkopts]

    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        user_link_flags = depset(expanded_linkopts),
        additional_inputs = depset(ctx.files.additional_linker_inputs),
    )

    linking_context = cc_common.create_linking_context(
        linker_inputs = depset([linker_input]),
    )

    own_cc_info = CcInfo(
        compilation_context = compilation_context,
        linking_context = linking_context,
    )

    dep_cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep]

    merged = cc_common.merge_cc_infos(
        direct_cc_infos = [own_cc_info],
        cc_infos = dep_cc_infos,
    )

    return [merged]

cc_deb_library = rule(
    implementation = _cc_deb_library_impl,
    attrs = {
        "hdrs": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [CcInfo]),
        "linkopts": attr.string_list(),
        "additional_compiler_inputs": attr.label_list(allow_files = True),
        "additional_linker_inputs": attr.label_list(allow_files = True),
    },
)
