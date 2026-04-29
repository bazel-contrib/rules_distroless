"unit tests for dependency set translation"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:translate_dependency_set.bzl", "package_deps_for_architecture")

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

def translate_dependency_set_tests():
    no_mixed_architectures_test(name = _TEST_SUITE_PREFIX + "no_mixed_architectures")
