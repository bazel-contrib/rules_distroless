"""Check the package inventory emitted for real Debian layers."""

load("@bazel_lib//lib:diff_test.bzl", "diff_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

_AWK = Label("@ape//ape:awk")
_COREUTILS = Label("@coreutils_toolchains//:resolved_toolchain")
_TAR = Label("@bsd_tar_toolchains//:resolved_toolchain")

def status_tests(compatible_with):
    """Check default and customized package inventories on supported platforms.

    Args:
        compatible_with: Target constraints for the package architectures.
    """
    for repo, packages in {
        "status_packages": [
            "base-files",
            "bash",
            "coreutils",
            "debianutils",
            "gcc-10-base",
            "libacl1",
            "libattr1",
            "libc6",
            "libcrypt1",
            "libgcc-s1",
            "libgmp10",
            "libpcre2-8-0",
            "libselinux1",
            "libtinfo6",
            "mawk",
            "ncurses-base",
        ],
        # The custom template deliberately drops all dependencies.
        "status_custom": ["tzdata"],
        # Repacking changes the data File identity; the template declares its controls.
        "status_repacked": [
            "debconf",
            "dpkg",
            "gcc-10-base",
            "libacl1",
            "libbz2-1.0",
            "libc6",
            "libcrypt1",
            "libgcc-s1",
            "liblzma5",
            "libpcre2-8-0",
            "libselinux1",
            "perl-base",
            "tar",
            "tzdata",
            "zlib1g",
        ],
    }.items():
        status = "@%s//:dpkg_status" % repo
        native.genrule(
            name = repo + "_actual",
            srcs = [status],
            outs = [repo + ".actual"],
            cmd = "$(BSDTAR_BIN) -xOf $(location %s) ./var/lib/dpkg/status | $(location %s) '/^Package:/ {print $$2}' | $(COREUTILS_BIN) sort > $@" % (status, _AWK),
            target_compatible_with = compatible_with,
            toolchains = [_TAR, _COREUTILS],
            tools = [_AWK],
        )
        write_file(
            name = repo + "_expected",
            out = repo + ".expected",
            content = sorted(packages) + [""],
        )
        diff_test(
            name = repo + "_test",
            file1 = ":" + repo + "_actual",
            file2 = ":" + repo + "_expected",
            target_compatible_with = compatible_with,
        )
