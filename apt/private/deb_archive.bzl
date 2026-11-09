"""Inspect Debian package archives with tar.bzl's host toolchain binary."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")

# Repository rules run before toolchain resolution. Use the same pinned
# binary tar.bzl makes available for the repository host.
def host_bsdtar(rctx):
    platform = repo_utils.platform(rctx)
    binary = "tar.exe" if platform.startswith("windows_") else "tar"
    return rctx.path(Label("@bsd_tar_toolchains_{}//:{}".format(platform, binary)))

def _member_archive(rctx, member, directory):
    archives = [path for path in rctx.path(directory).readdir() if path.basename.startswith(member + ".tar")]
    if len(archives) != 1:
        fail("expected one %s archive, found: %s" % (member, archives))
    return archives[0]

def data_archive(rctx, directory = "."):
    return _member_archive(rctx, "data", directory)

def control_archive(rctx, directory = "."):
    return _member_archive(rctx, "control", directory)
