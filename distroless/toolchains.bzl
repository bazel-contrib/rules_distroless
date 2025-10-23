"macro for registering toolchains required"

load("@bazel_lib//lib:repositories.bzl", "register_expand_template_toolchains", "register_tar_toolchains", "register_yq_toolchains", "register_zstd_toolchains")
load("@rules_java//java:repositories.bzl", "rules_java_toolchains")
load("@rules_java//java:rules_java_deps.bzl", "rules_java_dependencies")

def distroless_register_toolchains():
    """Register all toolchains required by distroless."""
    register_yq_toolchains()
    register_zstd_toolchains()
    register_tar_toolchains()
    register_expand_template_toolchains()
    rules_java_dependencies()
    rules_java_toolchains()
