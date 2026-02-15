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

    for dyn_lib in ctx.files.dynamic_libs:
        lib = cc_common.create_library_to_link(
            actions = ctx.actions,
            cc_toolchain = cc_toolchain,
            dynamic_library = dyn_lib,
            feature_configuration = feature_configuration,
        )
        libraries.append(lib)

    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libraries),
        additional_inputs = depset([]),
        # Use DT_RPATH instead of DT_RUNPATH so transitive ELF dependencies
        # from apt-provided shared libraries resolve inside Bazel's hermetic
        # solib tree without requiring an LD_LIBRARY_PATH wrapper.
        user_link_flags = depset(["-Wl,--disable-new-dtags"]),
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
