"unit tests for dependency set translation"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:translate_dependency_set.bzl", "dependency_set_package_selects")

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

def translate_dependency_set_tests():
    package_selects_test(name = _TEST_SUITE_PREFIX + "package_selects")
    deduplicate_package_names_test(name = _TEST_SUITE_PREFIX + "deduplicate_package_names")
