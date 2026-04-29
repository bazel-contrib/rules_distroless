"tests for deb_postfix"

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
        srcs = [":_deb_postfix_mergedusr_data"],
        outs = ["deb_postfix_layer.tar.gz"],
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
        srcs = [":_deb_postfix_basic_data"],
        outs = ["deb_postfix_basic.tar.gz"],
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
        srcs = [":_deb_postfix_gzip_data"],
        outs = ["deb_postfix_gzip_normalized.tar.gz"],
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

    # Test with xz-compressed input
    native.genrule(
        name = "_deb_postfix_xz_data",
        outs = ["lib_data.tar.xz"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
zstd="$$(pwd)/$(ZSTD_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/var/log"
touch "$$tmpdir/var/log/app.log"

cd "$$tmpdir"
# Create tar and pipe through xz
"$$bsdtar" -cf - ./var | xz -z > "$$out"
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain", "@zstd_toolchains//:resolved_toolchain"],
    )

    deb_postfix(
        name = "_deb_postfix_xz_layer",
        srcs = [":_deb_postfix_xz_data"],
        outs = ["deb_postfix_xz_normalized.tar.gz"],
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "xz_input",
        actual = ":_deb_postfix_xz_layer",
        expected = """\
./var/
./var/log/
./var/log/app.log
""",
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
        srcs = [":_deb_postfix_complex_data"],
        outs = ["deb_postfix_complex.tar.gz"],
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
