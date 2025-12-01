load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")

def _so_library_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        language = "c++",
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    libraries = []

    ifsos = {}

    for dyn_lib in ctx.files.dynamic_libs:
        if dyn_lib.owner.package != ctx.label.package:
            fail(".so libraries must reside in current package. %s != %s" % (dyn_lib.owner.package, ctx.label.package))
        short_path = dyn_lib.short_path
        repo_relative_path = short_path[short_path.find(dyn_lib.owner.repo_name) + len(dyn_lib.owner.repo_name) + 1:]
        ifso_name = repo_relative_path[:repo_relative_path.rfind("/")]
        if ifso_name in ifsos:
            ifso = ifsos[ifso_name]
        else:
            # TODO: this potentially wasterful, symlink all so libraries into a directory
            # and create one ifso in the folder.
            ifso = ctx.actions.declare_file(ifso_name + "/rpath.ifso")
            ifsos[ifso_name] = ifso
            ctx.actions.write(ifso, content = """
    /* GNU LD script
    * Empty linker script for empty interface library */
    """)
        lib = cc_common.create_library_to_link(
            actions = ctx.actions,
            cc_toolchain = cc_toolchain,
            interface_library = ifso,
            dynamic_library = dyn_lib,
            feature_configuration = feature_configuration,
        )
        libraries.append(lib)

    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libraries),
        additional_inputs = depset([]),
        user_link_flags = depset([]),
    )

    linking_context = cc_common.create_linking_context(
        linker_inputs = depset([linker_input]),
    )

    return [
        CcInfo(linking_context = linking_context),
    ]

so_library = rule(
    implementation = _so_library_impl,
    attrs = {
        "dynamic_libs": attr.label_list(allow_files = True),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
