"unit tests for dependency set translation"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:translate_dependency_set.bzl", "dependency_set_package_selects", "dependency_set_transitive_package_keys")
load("//apt/private:util.bzl", "util")

_TEST_SUITE_PREFIX = "translate_dependency_set/"

def _package_selects_test(ctx):
    env = unittest.begin(ctx)

    packages = {
        "/bullseye/bash:amd64=5.1": {"name": "bash"},
        "/bullseye/coreutils:amd64=8.32": {"name": "coreutils"},
        "/bullseye/ncurses-base:all=6.2": {"name": "ncurses-base"},
        "/bullseye/bash:arm64=5.1": {"name": "bash"},
    }

    dependency_set = {
        "sets": {
            "amd64": {
                "/bullseye/bash:amd64": "5.1",
                "/bullseye/coreutils:amd64": "8.32",
                "/bullseye/ncurses-base:all": "6.2",
            },
            "arm64": {
                "/bullseye/bash:arm64": "5.1",
                "/bullseye/ncurses-base:all": "6.2",
            },
        },
    }

    actual = dependency_set_package_selects(packages, dependency_set)
    expected = {
        "amd64": [
            "bash",
            "coreutils",
            "ncurses-base",
        ],
        "arm64": [
            "bash",
            "ncurses-base",
        ],
    }

    asserts.equals(env, expected, actual)
    return unittest.end(env)

package_selects_test = unittest.make(_package_selects_test)

def _deduplicate_package_names_test(ctx):
    env = unittest.begin(ctx)

    packages = {
        "/bullseye/bash:amd64=5.1": {"name": "bash"},
        "/bullseye-security/bash:amd64=5.2": {"name": "bash"},
    }

    dependency_set = {
        "sets": {
            "amd64": {
                "/bullseye/bash:amd64": "5.1",
                "/bullseye-security/bash:amd64": "5.2",
            },
        },
    }

    actual = dependency_set_package_selects(packages, dependency_set)
    asserts.equals(env, ["bash"], actual["amd64"])

    return unittest.end(env)

deduplicate_package_names_test = unittest.make(_deduplicate_package_names_test)

def _package_repo_name_modes_test(ctx):
    env = unittest.begin(ctx)

    package_key = "/bullseye/bash:amd64=5.1"

    asserts.equals(env, "bullseye_bash-amd64_5.1", util.package_repo_name(package_key))
    asserts.equals(env, "bullseye_bash-amd64_5.1_mergedusr", util.package_repo_name(package_key, mergedusr = True))

    return unittest.end(env)

package_repo_name_modes_test = unittest.make(_package_repo_name_modes_test)

def _dependency_closure_arch_filter_test(ctx):
    env = unittest.begin(ctx)

    packages = {
        "/noble/app:amd64=1": {
            "architecture": "amd64",
            "depends_on": [
                "/noble/libc6:amd64=1",
                "/noble/shared-tools:all=1",
            ],
        },
        "/noble/app:arm64=1": {
            "architecture": "arm64",
            "depends_on": [
                "/noble/libc6:arm64=1",
                "/noble/shared-tools:all=1",
            ],
        },
        "/noble/libc6:amd64=1": {
            "architecture": "amd64",
            "depends_on": [],
        },
        "/noble/libc6:arm64=1": {
            "architecture": "arm64",
            "depends_on": [],
        },
        "/noble/perl-base:amd64=1": {
            "architecture": "amd64",
            "depends_on": [],
        },
        "/noble/perl-base:arm64=1": {
            "architecture": "arm64",
            "depends_on": [],
        },
        "/noble/shared-tools:all=1": {
            "architecture": "all",
            "depends_on": [
                "/noble/perl-base:amd64=1",
                "/noble/perl-base:arm64=1",
            ],
        },
    }

    dependency_set = {
        "sets": {
            "amd64": {
                "/noble/app:amd64": "1",
            },
            "arm64": {
                "/noble/app:arm64": "1",
            },
            "all": {
                "/noble/shared-tools:all": "1",
            },
        },
    }

    amd64_keys = dependency_set_transitive_package_keys(packages, dependency_set, ["amd64", "all"])
    asserts.equals(env, [
        "/noble/app:amd64=1",
        "/noble/libc6:amd64=1",
        "/noble/perl-base:amd64=1",
        "/noble/shared-tools:all=1",
    ], amd64_keys)

    arm64_keys = dependency_set_transitive_package_keys(packages, dependency_set, ["arm64", "all"])
    asserts.equals(env, [
        "/noble/app:arm64=1",
        "/noble/libc6:arm64=1",
        "/noble/perl-base:arm64=1",
        "/noble/shared-tools:all=1",
    ], arm64_keys)

    return unittest.end(env)

dependency_closure_arch_filter_test = unittest.make(_dependency_closure_arch_filter_test)

def translate_dependency_set_tests():
    package_selects_test(name = _TEST_SUITE_PREFIX + "package_selects")
    deduplicate_package_names_test(name = _TEST_SUITE_PREFIX + "deduplicate_package_names")
    package_repo_name_modes_test(name = _TEST_SUITE_PREFIX + "package_repo_name_modes")
    dependency_closure_arch_filter_test(name = _TEST_SUITE_PREFIX + "dependency_closure_arch_filter")
