"unit tests for version parsing"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:version.bzl", "version")
load("//apt/private:version_constraint.bzl", "version_constraint")

_TEST_SUITE_PREFIX = "version/"

def _parse_test(ctx):
    parameters = {
        "1:1.4.1-1": ("1", "1.4.1", "1"),
        "7.1.ds-1": (None, "7.1.ds", "1"),
        "10.11.1.3-2": (None, "10.11.1.3", "2"),
        "4.0.1.3.dfsg.1-2": (None, "4.0.1.3.dfsg.1", "2"),
        "0.4.23debian1": (None, "0.4.23debian1", None),
        "1.2.10+cvs20060429-1": (None, "1.2.10+cvs20060429", "1"),
        "0.2.0-1+b1": (None, "0.2.0", "1+b1"),
        "4.3.90.1svn-r21976-1": (None, "4.3.90.1svn-r21976", "1"),
        "1.5+E-14": (None, "1.5+E", "14"),
        "20060611-0.0": (None, "20060611", "0.0"),
        "0.52.2-5.1": (None, "0.52.2", "5.1"),
        "7.0-035+1": (None, "7.0", "035+1"),
        "1.1.0+cvs20060620-1+2.6.15-8": (None, "1.1.0+cvs20060620-1+2.6.15", "8"),
        "1.1.0+cvs20060620-1+1.0": (None, "1.1.0+cvs20060620", "1+1.0"),
        "4.2.0a+stable-2sarge1": (None, "4.2.0a+stable", "2sarge1"),
        "1.8RC4b": (None, "1.8RC4b", None),
        "0.9~rc1-1": (None, "0.9~rc1", "1"),
        "2:1.0.4+svn26-1ubuntu1": ("2", "1.0.4+svn26", "1ubuntu1"),
        "2:1.0.4~rc2-1": ("2", "1.0.4~rc2", "1"),
    }

    env = unittest.begin(ctx)

    for v, expected in parameters.items():
        actual = version.parse(v)
        asserts.equals(env, actual, expected)

    return unittest.end(env)

parse_test = unittest.make(_parse_test)

def _operators_test(ctx):
    parameters = [
        ("0", version.lt, "a"),
        ("1.0", version.lt, "1.1"),
        ("1.2", version.lt, "1.11"),
        ("1.0-0.1", version.lt, "1.1"),
        ("1.0-0.1", version.lt, "1.0-1"),
        ("1.0", version.eq, "1.0"),
        ("1.0-0.1", version.eq, "1.0-0.1"),
        ("1:1.0-0.1", version.eq, "1:1.0-0.1"),
        ("1:1.0", version.eq, "1:1.0"),
        ("1.0-0.1", version.lt, "1.0-1"),
        ("1.0final-5sarge1", version.gt, "1.0final-5"),
        ("1.0final-5", version.gt, "1.0a7-2"),
        ("0.9.2-5", version.lt, "0.9.2+cvs.1.0.dev.2004.07.28-1.5"),
        ("1:500", version.lt, "1:5000"),
        ("100:500", version.gt, "11:5000"),
        ("1.0.4-2", version.gt, "1.0pre7-2"),
        ("1.5~rc1", version.lt, "1.5"),
        ("1.5~rc1", version.lt, "1.5+b1"),
        ("1.5~rc1", version.lt, "1.5~rc2"),
        ("1.5~rc1", version.gt, "1.5~dev0"),
    ]

    env = unittest.begin(ctx)
    for va, version_op, vb in parameters:
        asserts.true(env, version_op(va, vb))

    return unittest.end(env)

operators_test = unittest.make(_operators_test)

def _sort_test(ctx):
    parameters = [
        (
            ["1.5~rc2", "1.0.4-2", "1.5~rc1"],
            ["1.0.4-2", "1.5~rc1", "1.5~rc2"],
            False,
        ),
        (
            ["1.0a7-2", "1.0final-5sarge1", "1.0final-5"],
            ["1.0final-5sarge1", "1.0final-5", "1.0a7-2"],
            True,
        ),
    ]

    env = unittest.begin(ctx)

    for to_sort, expected, reversed in parameters:
        actual = version.sort(to_sort, reverse = reversed)
        asserts.equals(env, expected, actual)

    return unittest.end(env)

sort_test = unittest.make(_sort_test)

def _is_satisfied_by_test(ctx):
    parameters = [
        (">= 1.1", "= 1.1", True),
        ("<= 1.1", "= 1.1", True),
        (">> 1.1", "= 1.1", False),
        (">> 1.1", "= 1.1", False),
        (">= 246", "= 246.10", True),
        (">= 1.5~dev0", "= 1.5~rc1", True),
    ]

    env = unittest.begin(ctx)
    for va, vb, expected in parameters:
        asserts.equals(
            env,
            expected,
            version_constraint.is_satisfied_by(
                version_constraint.parse_version_constraint(va),
                version_constraint.parse_version_constraint(vb),
            ),
        )

    return unittest.end(env)

is_satisfied_by_test = unittest.make(_is_satisfied_by_test)

def version_tests():
    operators_test(name = _TEST_SUITE_PREFIX + "operators")
    parse_test(name = _TEST_SUITE_PREFIX + "parse")
    sort_test(name = _TEST_SUITE_PREFIX + "sort")
    is_satisfied_by_test(name = _TEST_SUITE_PREFIX + "is_satisfied_by")
