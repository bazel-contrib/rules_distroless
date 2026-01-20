"unit tests for resolution of package dependencies"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:apt_deb_repository.bzl", deb_repository = "DO_NOT_DEPEND_ON_THIS_TEST_ONLY")
load("//apt/private:apt_dep_resolver.bzl", "dependency_resolver")
load("//apt/private:version_constraint.bzl", "version_constraint")

def _parse_depends_test(ctx):
    env = unittest.begin(ctx)

    parameters = {
        " | ".join([
            "libc6 (>= 2.2.1), default-mta",
            "mail-transport-agent",
        ]): [
            {"name": "libc6", "version": (">=", "2.2.1"), "arch": None},
            [
                {"name": "default-mta", "version": None, "arch": None},
                {"name": "mail-transport-agent", "version": None, "arch": None},
            ],
        ],
        ", ".join([
            "libluajit5.1-dev [i386 amd64 powerpc mips]",
            "liblua5.1-dev [hurd-i386 ia64 s390x sparc]",
        ]): [
            {
                "name": "libluajit5.1-dev",
                "version": None,
                "arch": ["i386", "amd64", "powerpc", "mips"],
            },
            {
                "name": "liblua5.1-dev",
                "version": None,
                "arch": ["hurd-i386", "ia64", "s390x", "sparc"],
            },
        ],
        " | ".join([
            "emacs",
            "emacsen, make, debianutils (>= 1.7)",
        ]): [
            [
                {"name": "emacs", "version": None, "arch": None},
                {"name": "emacsen", "version": None, "arch": None},
            ],
            {"name": "make", "version": None, "arch": None},
            {"name": "debianutils", "version": (">=", "1.7"), "arch": None},
        ],
        ", ".join([
            "libcap-dev [!kfreebsd-i386 !hurd-i386]",
            "autoconf",
            "debhelper (>> 5.0.0)",
            "file",
            "libc6 (>= 2.7-1)",
            "libpaper1",
            "psutils",
        ]): [
            {"name": "libcap-dev", "version": None, "arch": ["!kfreebsd-i386", "!hurd-i386"]},
            {"name": "autoconf", "version": None, "arch": None},
            {"name": "debhelper", "version": (">>", "5.0.0"), "arch": None},
            {"name": "file", "version": None, "arch": None},
            {"name": "libc6", "version": (">=", "2.7-1"), "arch": None},
            {"name": "libpaper1", "version": None, "arch": None},
            {"name": "psutils", "version": None, "arch": None},
        ],
        "python3:any": [
            {"name": "python3", "version": None, "arch": ["any"]},
        ],
        " | ".join([
            "gcc-i686-linux-gnu (>= 4:10.2)",
            "gcc:i386, g++-i686-linux-gnu (>= 4:10.2)",
            "g++:i386, dpkg-cross",
        ]): [
            [
                {"name": "gcc-i686-linux-gnu", "version": (">=", "4:10.2"), "arch": None},
                {"name": "gcc", "version": None, "arch": ["i386"]},
            ],
            [
                {"name": "g++-i686-linux-gnu", "version": (">=", "4:10.2"), "arch": None},
                {"name": "g++", "version": None, "arch": ["i386"]},
            ],
            {"name": "dpkg-cross", "version": None, "arch": None},
        ],
        " | ".join([
            "gcc-x86-64-linux-gnu (>= 4:10.2)",
            "gcc:amd64, g++-x86-64-linux-gnu (>= 4:10.2)",
            "g++:amd64, dpkg-cross",
        ]): [
            [
                {"name": "gcc-x86-64-linux-gnu", "version": (">=", "4:10.2"), "arch": None},
                {"name": "gcc", "version": None, "arch": ["amd64"]},
            ],
            [
                {"name": "g++-x86-64-linux-gnu", "version": (">=", "4:10.2"), "arch": None},
                {"name": "g++", "version": None, "arch": ["amd64"]},
            ],
            {"name": "dpkg-cross", "version": None, "arch": None},
        ],
    }

    for deps, expected in parameters.items():
        actual = version_constraint.parse_depends(deps)
        asserts.equals(env, expected, actual)

    return unittest.end(env)

parse_depends_test = unittest.make(_parse_depends_test)

_test_version = "2.38.1-5"
_test_arch = "amd64"

def _make_index():
    idx = deb_repository.new()
    resolution = dependency_resolver.new(idx)

    def _add_package(idx, **kwargs):
        kwargs["architecture"] = kwargs.get("architecture", _test_arch)
        kwargs["version"] = kwargs.get("version", _test_version)
        dist = kwargs.pop("dist", "test")
        r = "\n".join(["{}: {}".format(item[0].title(), item[1]) for item in kwargs.items()])
        idx.parse_repository(r, dist = dist)

    return struct(
        add_package = lambda **kwargs: _add_package(idx, **kwargs),
        resolution = resolution,
        idx = idx,
        reset = lambda: idx.reset(),
    )

def _resolve_optionals_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Should pick the first alternative
    idx.add_package(package = "libc6-dev")
    idx.add_package(package = "eject", depends = "libc6-dev | libc-dev")

    (root_package, dependencies, _, _) = idx.resolution.resolve_all(
        name = "eject",
        version = ("=", _test_version),
        arch = _test_arch,
    )
    asserts.equals(env, "eject", root_package["Package"])
    asserts.equals(env, "libc6-dev", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    return unittest.end(env)

resolve_optionals_test = unittest.make(_resolve_optionals_test)

def _resolve_architecture_specific_packages_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    #  Should pick bar for amd64 and foo for i386
    idx.add_package(package = "foo", architecture = "i386")
    idx.add_package(package = "bar", architecture = "amd64")
    idx.add_package(package = "glibc", architecture = "all", depends = "foo [i386], bar [amd64]")

    # bar for amd64
    (root_package, dependencies, _, _) = idx.resolution.resolve_all(
        name = "glibc",
        version = ("=", _test_version),
        arch = "amd64",
    )
    asserts.equals(env, "glibc", root_package["Package"])
    asserts.equals(env, "all", root_package["Architecture"])
    asserts.equals(env, "bar", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    # foo for i386
    (root_package, dependencies, _, _) = idx.resolution.resolve_all(
        name = "glibc",
        version = ("=", _test_version),
        arch = "i386",
    )
    asserts.equals(env, "glibc", root_package["Package"])
    asserts.equals(env, "all", root_package["Architecture"])
    asserts.equals(env, "foo", dependencies[0]["Package"])
    asserts.equals(env, 1, len(dependencies))

    return unittest.end(env)

resolve_architecture_specific_packages_test = unittest.make(_resolve_architecture_specific_packages_test)

def _resolve_aliases(ctx):
    env = unittest.begin(ctx)

    def with_package(**kwargs):
        def add_package(idx):
            idx.add_package(**kwargs)

        return add_package

    def check_resolves(with_packages, resolved_name):
        idx = _make_index()

        for package in with_packages:
            package(idx)

        (root_package, dependencies, _, _) = idx.resolution.resolve_all(
            name = "foo",
            version = ("=", _test_version),
            arch = "amd64",
        )
        asserts.equals(env, "foo", root_package["Package"])
        asserts.equals(env, "amd64", root_package["Architecture"])

        if resolved_name:
            asserts.equals(env, 1, len(dependencies))
            asserts.equals(env, resolved_name, dependencies[0]["Package"])
        else:
            asserts.equals(env, 0, len(dependencies))

    # Version match
    check_resolves([
        with_package(package = "foo", depends = "bar (>= 1.0)"),
        with_package(package = "bar", version = "0.9"),
        with_package(package = "bar-plus", provides = "bar (= 1.0)"),
    ], resolved_name = "bar-plus")

    # Version match, ignores un-versioned
    check_resolves([
        with_package(package = "foo", depends = "bar (>= 1.0)"),
        with_package(package = "bar", version = "0.9"),
        with_package(package = "bar-plus", provides = "bar (= 1.0)"),
        with_package(package = "bar-clone", provides = "bar"),
    ], resolved_name = "bar-plus")

    # Un-versioned match
    check_resolves([
        with_package(package = "foo", depends = "bar"),
        with_package(package = "bar-plus", provides = "bar"),
    ], resolved_name = "bar-plus")

    # Un-versioned match, multiple provides
    check_resolves([
        with_package(package = "foo", depends = "bar"),
        with_package(package = "bar-plus", provides = "bar, baz"),
    ], resolved_name = "bar-plus")

    # Un-versioned match, versioned provides
    check_resolves([
        with_package(package = "foo", depends = "bar"),
        with_package(package = "bar-plus", provides = "bar (= 1.0)"),
    ], resolved_name = "bar-plus")

    # Un-versioned with multiple candidates - picks the latest version
    check_resolves([
        with_package(package = "foo", depends = "bar"),
        with_package(package = "bar-plus", provides = "bar"),
        with_package(package = "bar-plus2", provides = "bar"),
    ], resolved_name = "bar-plus2")

    return unittest.end(env)

resolve_aliases_test = unittest.make(_resolve_aliases)

def _resolve_circular_deps_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # `ruby` dependencies should have no `ruby`
    idx.add_package(package = "libruby")
    idx.add_package(package = "ruby3.1", depends = "ruby")
    idx.add_package(package = "ruby-rubygems", depends = "ruby3.1")
    idx.add_package(package = "ruby", depends = "libruby, ruby-rubygems")

    (root_package, dependencies, _, _) = idx.resolution.resolve_all(
        name = "ruby",
        version = "",
        arch = _test_arch,
    )
    asserts.equals(env, "ruby", root_package["Package"])
    asserts.equals(env, "ruby-rubygems", dependencies[0]["Package"])
    asserts.equals(env, 3, len(dependencies))
    asserts.false(env, "ruby" in [d["Package"] for d in dependencies], "Circular `ruby` dependency")

    return unittest.end(env)

resolve_circular_deps_test = unittest.make(_resolve_circular_deps_test)

def _resolve_suite_constraint_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Add same package name in different suites with different versions
    idx.add_package(package = "curl", version = "7.68.0", dist = "noble")
    idx.add_package(package = "curl", version = "7.88.0", dist = "jammy")

    # Without suite constraint - should get latest version (7.88.0 from jammy)
    (package, _) = idx.resolution.resolve_package(
        name = "curl",
        version = None,
        arch = _test_arch,
    )
    asserts.equals(env, "7.88.0", package["Version"])
    asserts.equals(env, "jammy", package["Dist"])

    # With suite constraint for noble - should get 7.68.0
    (package, _) = idx.resolution.resolve_package(
        name = "curl",
        version = None,
        arch = _test_arch,
        suites = ["noble"],
    )
    asserts.equals(env, "7.68.0", package["Version"])
    asserts.equals(env, "noble", package["Dist"])

    # With suite constraint for jammy - should get 7.88.0
    (package, _) = idx.resolution.resolve_package(
        name = "curl",
        version = None,
        arch = _test_arch,
        suites = ["jammy"],
    )
    asserts.equals(env, "7.88.0", package["Version"])
    asserts.equals(env, "jammy", package["Dist"])

    return unittest.end(env)

resolve_suite_constraint_test = unittest.make(_resolve_suite_constraint_test)

def _resolve_suite_constraint_not_found_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Add package only in noble suite
    idx.add_package(package = "noble-only-pkg", version = "1.0", dist = "noble")

    # Without suite constraint - should find it
    (package, _) = idx.resolution.resolve_package(
        name = "noble-only-pkg",
        version = None,
        arch = _test_arch,
    )
    asserts.equals(env, "noble-only-pkg", package["Package"])

    # With suite constraint for jammy - should NOT find it
    (package, _) = idx.resolution.resolve_package(
        name = "noble-only-pkg",
        version = None,
        arch = _test_arch,
        suites = ["jammy"],
    )
    asserts.equals(env, None, package)

    return unittest.end(env)

resolve_suite_constraint_not_found_test = unittest.make(_resolve_suite_constraint_not_found_test)

def _resolve_suite_constraint_transitive_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Add packages in noble suite
    idx.add_package(package = "libssl", version = "1.0", dist = "noble")
    idx.add_package(package = "curl", version = "7.68.0", depends = "libssl", dist = "noble")

    # Add packages in jammy suite
    idx.add_package(package = "libssl", version = "2.0", dist = "jammy")
    idx.add_package(package = "curl", version = "7.88.0", depends = "libssl", dist = "jammy")

    # Resolve curl with noble suite constraint - should get noble's libssl
    (root, deps, _, _) = idx.resolution.resolve_all(
        name = "curl",
        version = None,
        arch = _test_arch,
        suites = ["noble"],
    )
    asserts.equals(env, "curl", root["Package"])
    asserts.equals(env, "7.68.0", root["Version"])
    asserts.equals(env, "noble", root["Dist"])
    asserts.equals(env, 1, len(deps))
    asserts.equals(env, "libssl", deps[0]["Package"])
    asserts.equals(env, "1.0", deps[0]["Version"])
    asserts.equals(env, "noble", deps[0]["Dist"])

    # Resolve curl with jammy suite constraint - should get jammy's libssl
    (root, deps, _, _) = idx.resolution.resolve_all(
        name = "curl",
        version = None,
        arch = _test_arch,
        suites = ["jammy"],
    )
    asserts.equals(env, "curl", root["Package"])
    asserts.equals(env, "7.88.0", root["Version"])
    asserts.equals(env, "jammy", root["Dist"])
    asserts.equals(env, 1, len(deps))
    asserts.equals(env, "libssl", deps[0]["Package"])
    asserts.equals(env, "2.0", deps[0]["Version"])
    asserts.equals(env, "jammy", deps[0]["Dist"])

    return unittest.end(env)

resolve_suite_constraint_transitive_test = unittest.make(_resolve_suite_constraint_transitive_test)

def _resolve_suite_constraint_multiple_suites_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Add packages across multiple suites
    idx.add_package(package = "base-pkg", version = "1.0", dist = "noble")
    idx.add_package(package = "security-pkg", version = "1.1", dist = "noble-security")
    idx.add_package(package = "updates-pkg", version = "1.2", dist = "noble-updates")

    # Resolve with multiple suite constraint - should find packages in any of the suites
    (package, _) = idx.resolution.resolve_package(
        name = "base-pkg",
        version = None,
        arch = _test_arch,
        suites = ["noble", "noble-security", "noble-updates"],
    )
    asserts.equals(env, "base-pkg", package["Package"])
    asserts.equals(env, "noble", package["Dist"])

    (package, _) = idx.resolution.resolve_package(
        name = "security-pkg",
        version = None,
        arch = _test_arch,
        suites = ["noble", "noble-security", "noble-updates"],
    )
    asserts.equals(env, "security-pkg", package["Package"])
    asserts.equals(env, "noble-security", package["Dist"])

    # Package not in any of the specified suites
    idx.add_package(package = "other-pkg", version = "1.0", dist = "jammy")
    (package, _) = idx.resolution.resolve_package(
        name = "other-pkg",
        version = None,
        arch = _test_arch,
        suites = ["noble", "noble-security", "noble-updates"],
    )
    asserts.equals(env, None, package)

    return unittest.end(env)

resolve_suite_constraint_multiple_suites_test = unittest.make(_resolve_suite_constraint_multiple_suites_test)

def _resolve_virtual_package_suite_constraint_test(ctx):
    env = unittest.begin(ctx)

    idx = _make_index()

    # Add virtual package providers in different suites
    idx.add_package(package = "mawk", version = "1.0", provides = "awk", dist = "noble")
    idx.add_package(package = "gawk", version = "2.0", provides = "awk", dist = "jammy")

    # Without suite constraint - should pick one (gawk has higher version)
    (package, _) = idx.resolution.resolve_package(
        name = "awk",
        version = None,
        arch = _test_arch,
    )
    asserts.equals(env, "gawk", package["Package"])

    # With noble suite constraint - should get mawk
    (package, _) = idx.resolution.resolve_package(
        name = "awk",
        version = None,
        arch = _test_arch,
        suites = ["noble"],
    )
    asserts.equals(env, "mawk", package["Package"])
    asserts.equals(env, "noble", package["Dist"])

    # With jammy suite constraint - should get gawk
    (package, _) = idx.resolution.resolve_package(
        name = "awk",
        version = None,
        arch = _test_arch,
        suites = ["jammy"],
    )
    asserts.equals(env, "gawk", package["Package"])
    asserts.equals(env, "jammy", package["Dist"])

    return unittest.end(env)

resolve_virtual_package_suite_constraint_test = unittest.make(_resolve_virtual_package_suite_constraint_test)

_TEST_SUITE_PREFIX = "package_resolution/"

def resolution_tests():
    """Repository macro to create package resolution tests.

    The tests cover:
      - parse depend packages, e.g.,
        ```
        Package: gcc
        Depends: gcc-i686-linux-gnu, gcc-x86-64-linux-gnu
        ```
      - resolve optional packages, e.g.,
        ```
        Package: libc6-dev-amd64
        Depends: libc6-dev | libc-dev
        ```
      - resolve architecture specific packages, e.g.,
        ```
        Package: gcc:amd64
        ```
      - resolve aliases, e.g.,
        ```
        Package: foo
        Depends: bar (>= 1.0)

        Package: bar-plus
        Provides: bar (= 1.0)
        ```
      - resolve circular dependencies, e.g.,
        ```
        Package: ruby
        Depends: ruby-rubygems

        Package: ruby-rubygems
        Depends: ruby3.1

        Package: ruby3.1
        Depends: ruby
        ```
    """
    parse_depends_test(name = _TEST_SUITE_PREFIX + "parse_depends")
    resolve_optionals_test(name = _TEST_SUITE_PREFIX + "resolve_optionals")
    resolve_architecture_specific_packages_test(name = _TEST_SUITE_PREFIX + "resolve_architectures_specific")
    resolve_aliases_test(name = _TEST_SUITE_PREFIX + "resolve_aliases")
    resolve_circular_deps_test(name = _TEST_SUITE_PREFIX + "parse_circular")
    resolve_suite_constraint_test(name = _TEST_SUITE_PREFIX + "resolve_suite_constraint")
    resolve_suite_constraint_not_found_test(name = _TEST_SUITE_PREFIX + "resolve_suite_constraint_not_found")
    resolve_suite_constraint_transitive_test(name = _TEST_SUITE_PREFIX + "resolve_suite_constraint_transitive")
    resolve_suite_constraint_multiple_suites_test(name = _TEST_SUITE_PREFIX + "resolve_suite_constraint_multiple_suites")
    resolve_virtual_package_suite_constraint_test(name = _TEST_SUITE_PREFIX + "resolve_virtual_package_suite_constraint")
