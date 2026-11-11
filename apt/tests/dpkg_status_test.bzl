"tests for dpkg_status"

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//apt/private:dpkg_status.bzl", "dpkg_status")
load("//distroless/tests:asserts.bzl", "assert_tar_listing")

_TEST_SUITE_PREFIX = "dpkg_status/"

def dpkg_status_tests():
    # Test with single control archive
    native.genrule(
        name = "_dpkg_status_single_data",
        outs = ["dpkg_status_single.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir"
cat > "$$tmpdir/control" << 'EOF'
Package: test-package
Version: 1.0.0
Architecture: amd64
Maintainer: Test <test@example.com>
Description: A test package
EOF

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./control
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    dpkg_status(
        name = "_dpkg_status_single_layer",
        controls = [":_dpkg_status_single_data"],
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "single",
        actual = ":_dpkg_status_single_layer",
        expected = """\
./var/lib/dpkg/status
""",
    )

    # Test with multiple control archives (merge behavior)
    native.genrule(
        name = "_dpkg_status_multi_data1",
        outs = ["dpkg_status_multi1.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir"
cat > "$$tmpdir/control" << 'EOF'
Package: package1
Version: 1.0
Architecture: amd64
maintainer: Test <test@example.com>
Description: Package 1
EOF

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./control
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    native.genrule(
        name = "_dpkg_status_multi_data2",
        outs = ["dpkg_status_multi2.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir"
cat > "$$tmpdir/control" << 'EOF'
Package: package2
Version: 2.0
Architecture: amd64
Maintainer: Test <test@example.com>
Description: Package 2
EOF

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./control
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    dpkg_status(
        name = "_dpkg_status_multi_layer",
        controls = [":_dpkg_status_multi_data1", ":_dpkg_status_multi_data2"],
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "merge_multiple",
        actual = ":_dpkg_status_multi_layer",
        expected = """\
./var/lib/dpkg/status
""",
    )

    # Test with a base status the packages' entries are added to
    write_file(
        name = "_dpkg_status_base_file",
        out = "dpkg_status_base",
        content = [
            "Package: base-files",
            "Status: install ok installed",
            "Version: 12.4",
            "Architecture: amd64",
            "",
            "",
        ],
    )

    dpkg_status(
        name = "_dpkg_status_base_layer",
        controls = [":_dpkg_status_single_data"],
        base = ":_dpkg_status_base_file",
    )

    native.genrule(
        name = "_dpkg_status_base_actual",
        srcs = [":_dpkg_status_base_layer"],
        outs = ["dpkg_status_base_actual"],
        cmd = "$(BSDTAR_BIN) -xOf $< ./var/lib/dpkg/status > $@",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    write_file(
        name = "_dpkg_status_base_expected",
        out = "dpkg_status_base_expected",
        content = [
            "Package: base-files",
            "Status: install ok installed",
            "Version: 12.4",
            "Architecture: amd64",
            "",
            "Package: test-package",
            "Status: install ok installed",
            "Version: 1.0.0",
            "Architecture: amd64",
            "Maintainer: Test <test@example.com>",
            "Description: A test package",
            "",
            "",
        ],
    )

    diff_test(
        name = _TEST_SUITE_PREFIX + "base",
        file1 = ":_dpkg_status_base_actual",
        file2 = ":_dpkg_status_base_expected",
    )
