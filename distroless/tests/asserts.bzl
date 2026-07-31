"Make shorter assertions"

load("@bazel_lib//lib:diff_test.bzl", "diff_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

def assert_tar_mtree(name, actual, expected):
    """
    Assert that an mtree representation of a tarball matches an expected value.

    Args:
        name: name of this assertion
        actual: label for a tarball
        expected: expected mtree
    """
    actual_mtree = "_{}_mtree".format(name)
    expected_mtree = "_{}_expected".format(name)

    native.genrule(
        name = actual_mtree,
        srcs = [actual],
        outs = ["_{}.mtree".format(name)],
        cmd = "cat $(execpath {}) | $(BSDTAR_BIN) -cf $@ --format=mtree --options '!nlink' @-".format(actual),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    write_file(
        name = expected_mtree,
        out = "_{}.expected".format(name),
        content = [expected],
        newline = "unix",
    )

    diff_test(
        name = name,
        file1 = actual_mtree,
        file2 = expected_mtree,
        timeout = "short",
    )

def assert_tar_listing(name, actual, expected):
    """
    Assert that the listed contents of a tarball match an expected value. This is useful when checking for duplicated paths.

    Args:
        name: name of this assertion
        actual: label for a tarball
        expected: expected listing
    """
    actual_listing = "_{}_listing".format(name)
    expected_listing_raw = "_{}_expected_raw".format(name)
    expected_listing = "_{}_expected".format(name)

    # The order in which bsdtar lists tar members reflects the underlying
    # filesystem's directory-entry order, which is not guaranteed to be
    # stable across platforms/filesystems (e.g. ext4 htree hashing). Sort
    # both the actual and expected listings so this assertion only checks
    # for presence, absence and duplication of paths, not their order.
    native.genrule(
        name = actual_listing,
        srcs = [actual],
        outs = ["_{}.listing".format(name)],
        cmd = "cat $(execpath {}) | $(BSDTAR_BIN) -tf - | sort > $@".format(actual),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    write_file(
        name = expected_listing_raw,
        out = "_{}.expected_raw".format(name),
        content = [expected],
        newline = "unix",
    )

    native.genrule(
        name = expected_listing,
        srcs = [":" + expected_listing_raw],
        outs = ["_{}.expected".format(name)],
        cmd = "sort $< > $@",
    )

    diff_test(
        name = name,
        file1 = actual_listing,
        file2 = expected_listing,
        timeout = "short",
    )

# buildifier: disable=function-docstring
def assert_jks_listing(name, actual, expected):
    actual_listing = "_{}_listing".format(name)

    native.genrule(
        name = actual_listing,
        srcs = [
            actual,
            "@rules_java//toolchains:current_java_runtime",
        ],
        outs = ["_{}.listing".format(name)],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

BINS=($(locations @rules_java//toolchains:current_java_runtime))
KEYTOOL=$$(dirname $${BINS[1]})/keytool

$$KEYTOOL -J-Duser.language=en -J-Duser.country=US -J-Duser.timezone=UTC \\
-list -rfc -keystore $(location %s) -storepass changeit > $@
""" % actual,
    )

    diff_test(
        name = name,
        file1 = actual_listing,
        file2 = expected,
        timeout = "short",
    )
