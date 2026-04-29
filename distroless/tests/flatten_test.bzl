"tests for flatten"

load("//distroless:defs.bzl", "flatten")
load("//distroless/tests:asserts.bzl", "assert_tar_listing")

_TEST_SUITE_PREFIX = "flatten/"


def flatten_tests():
    # Test flattening two simple tar archives
    native.genrule(
        name = "_flatten_data_layer1",
        outs = ["flatten_layer1.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/bin" "$$tmpdir/usr/lib"
echo "tool1" > "$$tmpdir/usr/bin/tool1"
echo "libfoo.so" > "$$tmpdir/usr/lib/libfoo.so"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    native.genrule(
        name = "_flatten_data_layer2",
        outs = ["flatten_layer2.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/share/doc"
echo "readme" > "$$tmpdir/usr/share/doc/README"
echo "license" > "$$tmpdir/usr/share/doc/LICENSE"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    flatten(
        name = "_flatten_basic_layer",
        tars = [":_flatten_data_layer1", ":_flatten_data_layer2"],
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "merge_simple",
        actual = ":_flatten_basic_layer",
        expected = """\
./usr/
./usr/lib/
./usr/bin/
./usr/bin/tool1
./usr/lib/libfoo.so
./usr/
./usr/share/
./usr/share/doc/
./usr/share/doc/LICENSE
./usr/share/doc/README
""",
    )

    # Test flattening with deduplication
    native.genrule(
        name = "_flatten_dedup_layer1",
        outs = ["flatten_dedup1.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/bin" "$$tmpdir/etc"
echo "version1" > "$$tmpdir/usr/bin/app"
echo "config1" > "$$tmpdir/etc/app.conf"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr ./etc
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    native.genrule(
        name = "_flatten_dedup_layer2",
        outs = ["flatten_dedup2.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/usr/bin" "$$tmpdir/etc"
echo "version2" > "$$tmpdir/usr/bin/app"
echo "config2" > "$$tmpdir/etc/app.conf"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./usr ./etc
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    flatten(
        name = "_flatten_dedup_layer",
        tars = [":_flatten_dedup_layer1", ":_flatten_dedup_layer2"],
        deduplicate = True,
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "deduplicate",
        actual = ":_flatten_dedup_layer",
        expected = """\
./usr/
./usr/bin/
./usr/bin/app
./etc/
./etc/app.conf
""",
    )

    # Test flattening with compression (gzip)
    native.genrule(
        name = "_flatten_compress_data1",
        outs = ["flatten_compress1.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/opt/app/bin"
echo "app1" > "$$tmpdir/opt/app/bin/main"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./opt
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    native.genrule(
        name = "_flatten_compress_data2",
        outs = ["flatten_compress2.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir/opt/app/lib"
echo "lib1.a" > "$$tmpdir/opt/app/lib/lib1.a"

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./opt
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    flatten(
        name = "_flatten_compress_layer",
        tars = [":_flatten_compress_data1", ":_flatten_compress_data2"],
        compress = "gzip",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "gzip_compression",
        actual = ":_flatten_compress_layer",
        expected = """\
./opt/
./opt/app/
./opt/app/bin/
./opt/app/bin/main
./opt/
./opt/app/
./opt/app/lib/
./opt/app/lib/lib1.a
""",
    )
