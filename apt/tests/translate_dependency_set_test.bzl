"unit tests for dependency set translation"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:translate_dependency_set.bzl", "package_deps_for_architecture")
load("//apt/private:util.bzl", "util")

_TEST_SUITE_PREFIX = "translate_dependency_set/"

# Regression test for commit "Avoid mixing architectures": dpkg_status and
# packages targets accidentally mixed architectures, leading to file
# duplications which confuse flatten and lead to unusable artifacts. A
# package's `depends_on` (computed from the whole, possibly multi-arch,
# lockfile) must only contribute deps that match the architecture being
# built (or are architecture-independent).
def _no_mixed_architectures_test(ctx):
    env = unittest.begin(ctx)

    packages = {
        "/repo/libfoo:amd64=1.0": {
            "architecture": "amd64",
        },
        "/repo/libfoo:arm64=1.0": {
            "architecture": "arm64",
        },
        "/repo/libbar:all=1.0": {
            "architecture": "all",
        },
    }
    package = {
        "depends_on": [
            "/repo/libfoo:amd64=1.0",
            "/repo/libfoo:arm64=1.0",
            "/repo/libbar:all=1.0",
        ],
    }

    deps = package_deps_for_architecture(packages, package, "amd64")

    asserts.true(env, "@repo_libfoo-amd64_1.0//:data" in deps)
    asserts.true(env, "@repo_libbar-all_1.0//:data" in deps)
    asserts.false(env, "@repo_libfoo-arm64_1.0//:data" in deps)
    asserts.equals(env, 2, len(deps))

    return unittest.end(env)

no_mixed_architectures_test = unittest.make(_no_mixed_architectures_test)

# Regression test for commit "Add mergedusr support to apt.install()": package
# repo names must be distinguishable per mergedusr mode so that the same
# package can be materialized both with and without mergedusr normalization
# when pulled in by different apt.install roots.
def _package_repo_name_modes_test(ctx):
    env = unittest.begin(ctx)

    package_key = "/bullseye/bash:amd64=5.1"

    asserts.equals(env, "bullseye_bash-amd64_5.1", util.package_repo_name(package_key))
    asserts.equals(env, "bullseye_bash-amd64_5.1_mergedusr", util.package_repo_name(package_key, mergedusr = True))

    return unittest.end(env)

package_repo_name_modes_test = unittest.make(_package_repo_name_modes_test)

def translate_dependency_set_tests():
    no_mixed_architectures_test(name = _TEST_SUITE_PREFIX + "no_mixed_architectures")
    package_repo_name_modes_test(name = _TEST_SUITE_PREFIX + "package_repo_name_modes")
