"tests for deb_postfix"

load("@bazel_lib//lib:copy_file.bzl", "copy_file")
load("@bazel_lib//lib:diff_test.bzl", "diff_test")
load("//apt/private:deb_postfix.bzl", "deb_postfix")
load("//distroless/tests:asserts.bzl", "assert_tar_listing")

_TEST_SUITE_PREFIX = "deb_postfix/"

def deb_postfix_tests():
    native.genrule(
        name = "_deb_postfix_mergedusr_data",
        outs = ["deb_postfix_data.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/bin" "$$tmpdir/sbin" "$$tmpdir/lib" "$$tmpdir/usr/share/doc"
: > "$$tmpdir/bin/tool"
: > "$$tmpdir/sbin/helper"
: > "$$tmpdir/lib/libfoo.so"
: > "$$tmpdir/usr/share/doc/keep"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./bin ./sbin ./lib ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    deb_postfix(
        name = "_deb_postfix_mergedusr_layer",
        src = ":_deb_postfix_mergedusr_data",
        out = "deb_postfix_layer.tar.gz",
        mergedusr = True,
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "mergedusr",
        actual = ":_deb_postfix_mergedusr_layer",
        expected = """\
./usr/bin/tool
./usr/sbin/helper
./usr/lib/libfoo.so
./usr/
./usr/share/
./usr/share/doc/
./usr/share/doc/keep
""",
    )

    # Test basic normalization without mergedusr (uncompressed tar input)
    native.genrule(
        name = "_deb_postfix_basic_data",
        outs = ["basic_data.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/bin" "$$tmpdir/usr/lib"
echo "executable" > "$$tmpdir/usr/bin/app"
echo "library" > "$$tmpdir/usr/lib/libapp.so"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    deb_postfix(
        name = "_deb_postfix_basic_layer",
        src = ":_deb_postfix_basic_data",
        out = "deb_postfix_basic.tar.gz",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "basic_normalization",
        actual = ":_deb_postfix_basic_layer",
        expected = """\
./usr/
./usr/lib/
./usr/bin/
./usr/bin/app
./usr/lib/libapp.so
""",
    )

    # Test with pre-gzipped input (already compressed)
    native.genrule(
        name = "_deb_postfix_gzip_data",
        outs = ["pkg_data.tar.gz"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/etc/config"
echo "config_value=1" > "$$tmpdir/etc/config/app.conf"

cd "$$tmpdir"
"$$bsdtar" -czf "$$out" ./etc
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    deb_postfix(
        name = "_deb_postfix_gzip_layer",
        src = ":_deb_postfix_gzip_data",
        out = "deb_postfix_gzip_normalized.tar.gz",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "gzip_input",
        actual = ":_deb_postfix_gzip_layer",
        expected = """\
./etc/
./etc/config/
./etc/config/app.conf
""",
    )

    diff_test(
        name = _TEST_SUITE_PREFIX + "gzip_passthrough",
        file1 = ":_deb_postfix_gzip_data",
        file2 = ":_deb_postfix_gzip_layer",
    )

    # The gzip alias on standard input is the reference for the layer bytes:
    # it omits the source name and timestamp, and preserves the whole tar.
    native.genrule(
        name = "_deb_postfix_reference",
        srcs = [":_deb_postfix_basic_data"],
        outs = ["reference.tar.gz"],
        cmd = '(exec -a gzip "$(ZSTD_BIN)" -n) < "$<" > "$@"',
        toolchains = ["@zstd_toolchains//:resolved_toolchain"],
    )
    diff_test(
        name = _TEST_SUITE_PREFIX + "uncompressed_bytes",
        file1 = ":_deb_postfix_reference",
        file2 = ":_deb_postfix_basic_layer",
    )

    for extension, compression in [("xz", "xz"), ("zst", "zstd"), ("lzma", "lzma")]:
        data = "_deb_postfix_%s_data" % extension
        layer = "_deb_postfix_%s_layer" % extension
        native.genrule(
            name = data,
            srcs = [":_deb_postfix_basic_data"],
            outs = ["lib_data.tar.%s" % extension],
            cmd = '"$(ZSTD_BIN)" --force --format=%s "$<" -o "$@"' % compression,
            toolchains = ["@zstd_toolchains//:resolved_toolchain"],
        )
        deb_postfix(
            name = layer,
            src = ":" + data,
            out = "deb_postfix_%s_normalized.tar.gz" % extension,
        )
        diff_test(
            name = _TEST_SUITE_PREFIX + extension + "_input",
            file1 = ":_deb_postfix_reference",
            file2 = ":" + layer,
        )

    copy_file(
        name = "_deb_postfix_uncompressed_as_zstd",
        src = ":_deb_postfix_basic_data",
        out = "uncompressed_data.tar.zst",
    )
    deb_postfix(
        name = "_deb_postfix_uncompressed_as_zstd_layer",
        src = ":_deb_postfix_uncompressed_as_zstd",
        out = "uncompressed_as_zstd.tar.gz",
    )
    diff_test(
        name = _TEST_SUITE_PREFIX + "uncompressed_as_zstd",
        file1 = ":_deb_postfix_reference",
        file2 = ":_deb_postfix_uncompressed_as_zstd_layer",
    )

    # Test with complex directory structure (multiple levels)
    native.genrule(
        name = "_deb_postfix_complex_data",
        outs = ["complex_data.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/share/doc/myapp"
mkdir -p "$$tmpdir/usr/share/man/man1"
mkdir -p "$$tmpdir/usr/local/bin"

echo "documentation" > "$$tmpdir/usr/share/doc/myapp/README"
echo ".TH myapp" > "$$tmpdir/usr/share/man/man1/myapp.1"
echo "#!/bin/sh" > "$$tmpdir/usr/local/bin/myapp"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    deb_postfix(
        name = "_deb_postfix_complex_layer",
        src = ":_deb_postfix_complex_data",
        out = "deb_postfix_complex.tar.gz",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "complex_structure",
        actual = ":_deb_postfix_complex_layer",
        expected = """\
./usr/
./usr/local/
./usr/share/
./usr/share/man/
./usr/share/doc/
./usr/share/doc/myapp/
./usr/share/doc/myapp/README
./usr/share/man/man1/
./usr/share/man/man1/myapp.1
./usr/local/bin/
./usr/local/bin/myapp
""",
    )
