"unit tests for deb_archive"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:deb_archive.bzl", "control_archive")

_TEST_SUITE_PREFIX = "deb_archive/"

def _fake_rctx(members):
    return struct(
        path = lambda _directory: struct(
            readdir = lambda: [struct(basename = member) for member in members],
        ),
    )

def _control_archive_test(ctx):
    env = unittest.begin(ctx)

    for member in ["control.tar", "control.tar.gz", "control.tar.xz", "control.tar.zst"]:
        rctx = _fake_rctx(["debian-binary", member, "data.tar.xz", "_gpgbuilder"])
        asserts.equals(env, member, control_archive(rctx).basename)

    return unittest.end(env)

control_archive_test = unittest.make(_control_archive_test)

def deb_archive_tests():
    control_archive_test(name = _TEST_SUITE_PREFIX + "control_archive")
