"unit tests for apt.install mergedusr scoping"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt:extensions.bzl", "compute_package_repo_modes", "filter_package_templates", "package_purl", "resolve_vendor")

_TEST_SUITE_PREFIX = "extensions/"

# Regression test for commit "Add mergedusr support to apt.install()".
#
# Before this fix, mergedusr was tracked as a single global boolean
# (`mergedusr_enabled`) across *all* `apt.install` calls in a module, so a
# single `apt.install(mergedusr = True)` call would force every other
# `apt.install` call (even ones that never asked for mergedusr) to also be
# built in mergedusr mode. `_package_repo_modes` instead computes, per
# package, exactly which modes (mergedusr True/False) are actually needed
# based on which root installs pulled it in transitively.
def _scoped_mergedusr_test(ctx):
    env = unittest.begin(ctx)

    packages = {
        "pkg-a": {"depends_on": []},
        "pkg-b": {"depends_on": []},
        "shared-dep": {"depends_on": []},
    }

    # Two independent apt.install roots: one with mergedusr=True (pkg-a),
    # one without (pkg-b). Both depend on shared-dep.
    roots_by_mode = {
        False: {"pkg-b": True, "shared-dep": True},
        True: {"pkg-a": True, "shared-dep": True},
    }

    modes = compute_package_repo_modes(packages, roots_by_mode)

    # pkg-a only ever needed in mergedusr mode.
    asserts.true(env, True in modes["pkg-a"])
    asserts.false(env, False in modes["pkg-a"])

    # pkg-b only ever needed without mergedusr.
    asserts.true(env, False in modes["pkg-b"])
    asserts.false(env, True in modes["pkg-b"])

    # shared-dep is needed in BOTH modes, since it's pulled in by both roots.
    # This is the crux of the fix: a single global flag could not represent this.
    asserts.true(env, False in modes["shared-dep"])
    asserts.true(env, True in modes["shared-dep"])

    return unittest.end(env)

scoped_mergedusr_test = unittest.make(_scoped_mergedusr_test)

def _filter_package_templates_test(ctx):
    env = unittest.begin(ctx)

    templates = [
        {
            "dependency_sets": ["trixie_java"],
            "packages": ["*"],
            "template": "trixie_template",
        },
        {
            "dependency_sets": [],
            "packages": ["*"],
            "template": "global_template",
        },
        {
            "dependency_sets": ["bullseye", "bookworm"],
            "packages": ["nginx-*"],
            "template": "nginx_template",
        },
    ]

    # Matching trixie_java
    trixie = filter_package_templates(templates, "trixie_java")
    asserts.equals(env, ["trixie_template", "global_template"], [t["template"] for t in trixie])

    # Matching bullseye
    bullseye = filter_package_templates(templates, "bullseye")
    asserts.equals(env, ["global_template", "nginx_template"], [t["template"] for t in bullseye])

    # Matching other set
    other = filter_package_templates(templates, "other_set")
    asserts.equals(env, ["global_template"], [t["template"] for t in other])

    return unittest.end(env)

filter_package_templates_test = unittest.make(_filter_package_templates_test)

def _resolve_vendor_test(ctx):
    env = unittest.begin(ctx)

    # The vendor is derived from the lowercased, trimmed Release `Origin`.
    asserts.equals(env, "debian", resolve_vendor("bookworm", "", "Debian", False))
    asserts.equals(env, "ubuntu", resolve_vendor("noble", "", "Ubuntu", False))
    asserts.equals(env, "docker", resolve_vendor("bookworm", "", "Docker", False))
    asserts.equals(env, "cloud-sdk", resolve_vendor("cloud-sdk", "", " cloud-sdk ", False))

    # Whitespace becomes `-`, and official sub-archives map to their distribution.
    asserts.equals(env, "raspberry-pi-foundation", resolve_vendor("bookworm", "", "Raspberry Pi Foundation", False))
    asserts.equals(env, "lp-ppa-deadsnakes", resolve_vendor("noble", "", "LP-PPA-deadsnakes", False))
    asserts.equals(env, "debian", resolve_vendor("bookworm-backports", "", "Debian Backports", False))
    asserts.equals(env, "debian", resolve_vendor("bookworm-backports", "", "Debian Backports", True))

    # An explicit vendor always wins over the Origin, lowercased as the PURL spec requires.
    asserts.equals(env, "debian", resolve_vendor("bookworm", "debian", "Docker", False))
    asserts.equals(env, "debian", resolve_vendor("bookworm", "Debian", "Docker", False))
    asserts.equals(env, "acme", resolve_vendor("custom", "acme", "", False))

    # Strict mode accepts the known vendors when derived ...
    asserts.equals(env, "debian", resolve_vendor("bookworm", "", "Debian", True))
    asserts.equals(env, "ubuntu", resolve_vendor("noble", "", "Ubuntu", True))

    # ... and any explicit vendor, which is the escape hatch for other origins.
    asserts.equals(env, "docker", resolve_vendor("bookworm", "docker", "Docker", True))
    asserts.equals(env, "debian", resolve_vendor("bookworm", "debian", "Docker", True))

    return unittest.end(env)

resolve_vendor_test = unittest.make(_resolve_vendor_test)

def _package_purl_test(ctx):
    env = unittest.begin(ctx)

    # Examples from the purl-spec deb type definition.
    asserts.equals(env, "pkg:deb/debian/curl@7.50.3-1?arch=i386&distro=jessie", package_purl("debian", "curl", "7.50.3-1", "i386", "jessie"))
    asserts.equals(env, "pkg:deb/ubuntu/dpkg@1.19.0.4?arch=amd64", package_purl("ubuntu", "dpkg", "1.19.0.4", "amd64"))
    asserts.equals(env, "pkg:deb/debian/attr@1:2.4.47-2%2Bb1?arch=amd64", package_purl("debian", "attr", "1:2.4.47-2+b1", "amd64"))

    # Sub-suite codenames and derived third-party vendors pass through.
    asserts.equals(env, "pkg:deb/debian/bash@5.2.15-2?arch=arm64&distro=bookworm-security", package_purl("debian", "bash", "5.2.15-2", "arm64", "bookworm-security"))
    asserts.equals(env, "pkg:deb/cloud-sdk/kubectl@1.34.1-00?arch=amd64&distro=cloud-sdk", package_purl("cloud-sdk", "kubectl", "1.34.1-00", "amd64", "cloud-sdk"))

    # Checksum and file name qualifiers.
    asserts.equals(env, "pkg:deb/debian/adduser@3.152?arch=all&checksum=sha256:abc&distro=trixie&file_name=adduser_3.152_all.deb", package_purl("debian", "adduser", "3.152", "all", "trixie", "abc", "adduser_3.152_all.deb"))

    return unittest.end(env)

package_purl_test = unittest.make(_package_purl_test)

def extensions_tests():
    scoped_mergedusr_test(name = _TEST_SUITE_PREFIX + "scoped_mergedusr")
    filter_package_templates_test(name = _TEST_SUITE_PREFIX + "filter_package_templates")
    resolve_vendor_test(name = _TEST_SUITE_PREFIX + "resolve_vendor")
    package_purl_test(name = _TEST_SUITE_PREFIX + "package_purl")
