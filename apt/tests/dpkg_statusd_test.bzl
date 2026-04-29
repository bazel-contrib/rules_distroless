"tests for dpkg_statusd"

load("//apt/private:dpkg_statusd.bzl", "dpkg_statusd")
load("//distroless/tests:asserts.bzl", "assert_tar_listing")

_TEST_SUITE_PREFIX = "dpkg_statusd/"


def dpkg_statusd_tests():
    # Test basic dpkg_statusd with single package
    native.genrule(
        name = "_dpkg_statusd_basic_data",
        outs = ["dpkg_statusd_basic.tar"],
        cmd = """
#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

tmpdir=$$(mktemp -d)
bsdtar="$$(pwd)/$(BSDTAR_BIN)"
out="$$(pwd)/$@"
trap 'rm -rf "$$tmpdir"' EXIT

mkdir -p "$$tmpdir"
cat > "$$tmpdir/control" << 'EOF'
Package: test-pkg
Version: 1.0.0
Architecture: amd64
Maintainer: Test <test@example.com>
Description: A test package
EOF

cat > "$$tmpdir/md5sums" << 'EOF'
1234567890abcdef1234567890abcdef  /usr/bin/test
EOF

cd "$$tmpdir"
"$$bsdtar" -cf "$$out" ./control ./md5sums
""",
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
    )

    dpkg_statusd(
        name = "_dpkg_statusd_basic_layer",
        control = ":_dpkg_statusd_basic_data",
        package_name = "test-pkg",
    )

    assert_tar_listing(
        name = _TEST_SUITE_PREFIX + "basic",
        actual = ":_dpkg_statusd_basic_layer",
        expected = """\
./var/lib/dpkg/status.d/test-pkg
./var/lib/dpkg/status.d/test-pkg.md5sums
""",
    )
