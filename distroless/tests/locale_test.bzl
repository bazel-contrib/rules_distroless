"tests for locale"

load("//distroless:defs.bzl", "locale")
load("//distroless/tests:asserts.bzl", "assert_tar_listing")

_TEST_SUITE_PREFIX = "locale/"


def locale_tests():
    # Test basic locale extraction
    native.genrule(
        name = "_locale_data_basic",
        outs = ["locale_basic.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/lib/locale/C.utf8/LC_COLLATE" "$$tmpdir/usr/share/doc/libc-bin"
echo "collate_data" > "$$tmpdir/usr/lib/locale/C.utf8/LC_COLLATE/COLLATE"
echo "LICENSE" > "$$tmpdir/usr/share/doc/libc-bin/copyright"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    locale(
        name = "_locale_basic_layer",
        package = ":_locale_data_basic",
        charset = "C.utf8",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "basic_extraction",
        actual = ":_locale_basic_layer",
        expected = """\
./usr/
./usr/lib/
./usr/lib/locale/
./usr/lib/locale/C.utf8/
./usr/lib/locale/C.utf8/LC_COLLATE/
./usr/lib/locale/C.utf8/LC_COLLATE/COLLATE
./usr/share/
./usr/share/doc/
./usr/share/doc/libc-bin/
./usr/share/doc/libc-bin/copyright
""",
    )

    # Test locale with multiple character sets (keeps only specified one)
    native.genrule(
        name = "_locale_data_multi",
        outs = ["locale_multi.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/lib/locale/C.utf8/LC_COLLATE"
mkdir -p "$$tmpdir/usr/lib/locale/en_US.UTF-8/LC_COLLATE"
mkdir -p "$$tmpdir/usr/lib/locale/de_DE.UTF-8/LC_COLLATE"
mkdir -p "$$tmpdir/usr/share/doc/libc-bin"

echo "utf8_collate" > "$$tmpdir/usr/lib/locale/C.utf8/LC_COLLATE/COLLATE"
echo "en_collate" > "$$tmpdir/usr/lib/locale/en_US.UTF-8/LC_COLLATE/COLLATE"
echo "de_collate" > "$$tmpdir/usr/lib/locale/de_DE.UTF-8/LC_COLLATE/COLLATE"
echo "COPYRIGHT" > "$$tmpdir/usr/share/doc/libc-bin/copyright"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    locale(
        name = "_locale_en_us_layer",
        package = ":_locale_data_multi",
        charset = "en_US.UTF-8",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "filtered_charset",
        actual = ":_locale_en_us_layer",
        expected = """\
./usr/
./usr/lib/
./usr/lib/locale/
./usr/lib/locale/en_US.UTF-8/
./usr/lib/locale/en_US.UTF-8/LC_COLLATE/
./usr/lib/locale/en_US.UTF-8/LC_COLLATE/COLLATE
./usr/share/
./usr/share/doc/
./usr/share/doc/libc-bin/
./usr/share/doc/libc-bin/copyright
""",
    )

    # Test locale with custom time parameter
    native.genrule(
        name = "_locale_data_time",
        outs = ["locale_time.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/lib/locale/C.utf8/LC_TIME" "$$tmpdir/usr/share/doc/libc-bin"
echo "time_data" > "$$tmpdir/usr/lib/locale/C.utf8/LC_TIME/TIME"
echo "LICENSE" > "$$tmpdir/usr/share/doc/libc-bin/copyright"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    locale(
        name = "_locale_custom_time_layer",
        package = ":_locale_data_time",
        charset = "C.utf8",
        time = "1672560000",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "custom_time",
        actual = ":_locale_custom_time_layer",
        expected = """\
./usr/
./usr/lib/
./usr/lib/locale/
./usr/lib/locale/C.utf8/
./usr/lib/locale/C.utf8/LC_TIME/
./usr/lib/locale/C.utf8/LC_TIME/TIME
./usr/share/
./usr/share/doc/
./usr/share/doc/libc-bin/
./usr/share/doc/libc-bin/copyright
""",
    )
