"unit tests for apt utility functions"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:util.bzl", "util")

_TEST_SUITE_PREFIX = "util/"

def _glob_match_test(ctx):
    env = unittest.begin(ctx)

    # Universal wildcard
    asserts.true(env, util.glob_match("*", "anything"))
    asserts.true(env, util.glob_match("*", ""))
    asserts.true(env, util.glob_match("*", "libc6"))

    # Exact matches
    asserts.true(env, util.glob_match("libc6", "libc6"))
    asserts.false(env, util.glob_match("libc6", "libc6-dev"))
    asserts.false(env, util.glob_match("libc6", "libm"))
    asserts.true(env, util.glob_match("", ""))
    asserts.false(env, util.glob_match("", "foo"))

    # Prefix match
    asserts.true(env, util.glob_match("nvidia-*", "nvidia-driver"))
    asserts.true(env, util.glob_match("nvidia-*", "nvidia-smi"))
    asserts.true(env, util.glob_match("nvidia-*", "nvidia-"))
    asserts.false(env, util.glob_match("nvidia-*", "libnvidia-driver"))
    asserts.false(env, util.glob_match("nvidia-*", "nvid"))

    # Suffix match
    asserts.true(env, util.glob_match("*-dev", "libc6-dev"))
    asserts.true(env, util.glob_match("*-dev", "libssl-dev"))
    asserts.true(env, util.glob_match("*-dev", "-dev"))
    asserts.false(env, util.glob_match("*-dev", "libc6-dev-doc"))
    asserts.false(env, util.glob_match("*-dev", "dev"))

    # Middle wildcard
    asserts.true(env, util.glob_match("lib*-dev", "libc6-dev"))
    asserts.true(env, util.glob_match("lib*-dev", "libssl-dev"))
    asserts.true(env, util.glob_match("lib*-dev", "lib-dev"))
    asserts.false(env, util.glob_match("lib*-dev", "libc6"))
    asserts.false(env, util.glob_match("lib*-dev", "libssl-dbg"))

    # Multiple wildcards
    asserts.true(env, util.glob_match("*foo*bar*", "1foo2bar3"))
    asserts.true(env, util.glob_match("*foo*bar*", "foobar"))
    asserts.false(env, util.glob_match("*foo*bar*", "barfoo"))
    asserts.false(env, util.glob_match("*foo*bar*", "foo"))

    return unittest.end(env)

glob_match_test = unittest.make(_glob_match_test)

def util_tests():
    glob_match_test(name = _TEST_SUITE_PREFIX + "glob_match")
