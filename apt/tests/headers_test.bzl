"""Tests for Debian SDK include fragments."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:headers.bzl", "is_include_fragment")

_TEST_SUITE_PREFIX = "headers/"

def _supported_fragments_test(ctx):
    env = unittest.begin(ctx)

    for path in [
        "usr/include/example/header.hh",
        "usr/include/boost/spirit/home/classic/utility/impl/chset/basic_chset.ipp",
        "usr/include/example/header.hxx",
        "usr/include/example/header.h++",
        "usr/include/example/header.inc",
        "usr/include/example/header.inl",
        "usr/include/example/header.tlh",
        "usr/include/example/header.tli",
        "usr/include/example/header.H",
        "usr/include/example/header.tcc",
        "usr/include/boost/xpressive/detail/utility/chset/basic_chset.ipp",
        "usr/include/x86_64-linux-gnu/example/header.ipp",
        "usr/include/aarch64-linux-gnu/example/header.tcc",
    ]:
        asserts.true(env, is_include_fragment(path), path)

    return unittest.end(env)

supported_fragments_test = unittest.make(_supported_fragments_test)

def _exclude_non_include_paths_test(ctx):
    env = unittest.begin(ctx)

    # A matching extension outside the installed include directory must not
    # pull documentation, sample source files or host paths into CcInfo.
    for path in [
        "usr/share/doc/example/sample.ipp",
        "usr/lib/example/config.inc",
        "usr/include-other/example.ipp",
        "usr/include.ipp",
        "opt/vendor/usr/include/example.ipp",
        "/usr/include/example.ipp",
        "include/example.ipp",
        "",
    ]:
        asserts.false(env, is_include_fragment(path), path)

    return unittest.end(env)

exclude_non_include_paths_test = unittest.make(_exclude_non_include_paths_test)

def _exclude_other_suffixes_test(ctx):
    env = unittest.begin(ctx)

    for path in [
        "usr/include/example/header.ipp.bak",
        "usr/include/example/header.ipp.cc",
        "usr/include/example/ipp",
        "usr/include/example/header.cpp",
        "usr/include/example/header.IPp",
        "usr/include/example/header.txt",
        # Existing .h, .hpp and extensionless handling remains in deb_import.
        "usr/include/example/header.h",
        "usr/include/example/header.hpp",
        "usr/include/c++/12/vector",
    ]:
        asserts.false(env, is_include_fragment(path), path)

    return unittest.end(env)

exclude_other_suffixes_test = unittest.make(_exclude_other_suffixes_test)

def headers_tests():
    supported_fragments_test(name = _TEST_SUITE_PREFIX + "supported_fragments")
    exclude_non_include_paths_test(name = _TEST_SUITE_PREFIX + "exclude_non_include_paths")
    exclude_other_suffixes_test(name = _TEST_SUITE_PREFIX + "exclude_other_suffixes")
