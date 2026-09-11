"""Inspect Debian data archives with tar.bzl's host toolchain binary."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")

# Repository rules run before toolchain resolution. Use the same pinned
# binary tar.bzl makes available for the repository host.
def host_bsdtar(rctx):
    platform = repo_utils.platform(rctx)
    binary = "tar.exe" if platform.startswith("windows_") else "tar"
    return rctx.path(Label("@bsd_tar_toolchains_{}//:{}".format(platform, binary)))

def data_archive(rctx, directory = "."):
    archives = [path for path in rctx.path(directory).readdir() if path.basename.startswith("data.tar")]
    if len(archives) != 1:
        fail("expected one data archive, found: %s" % archives)
    return archives[0]
