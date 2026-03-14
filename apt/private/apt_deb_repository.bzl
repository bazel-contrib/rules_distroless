"https://wiki.debian.org/DebianRepository"

load(":util.bzl", "util")
load(":version_constraint.bzl", "version_constraint")

def _parse_repository(state, contents, roots, dist):
    last_key = ""
    pkg = {}
    for group in contents.split("\n\n"):
        for line in group.split("\n"):
            if line.strip() == "":
                continue
            if line[0] == " ":
                pkg[last_key] += "\n" + line
                continue

            # This allows for (more) graceful parsing of Package metadata (such as X-* attributes)
            # which may contain patterns that are non-standard. This logic is intended to closely follow
            # the Debian team's parser logic:
            # * https://salsa.debian.org/python-debian-team/python-debian/-/blob/master/src/debian/deb822.py?ref_type=heads#L788
            split = line.split(": ", 1)
            key = split[0]
            value = ""

            if len(split) == 2:
                value = split[1]

            last_key = key
            pkg[key] = value

        if len(pkg.keys()) != 0:
            if "Package" not in pkg:
                fail("Invalid debian package index format. No 'Package' key found in entry: {}".format(pkg))
            pkg["Roots"] = roots
            pkg["Dist"] = dist
            _add_package(state, pkg)
            last_key = ""
            pkg = {}

def _parse_contents(state, rcontents, arch):
    contents = state.filemap.setdefault(arch, {})
    for line in rcontents.splitlines():
        last_empty_char = line.rfind(" ")
        first_empty_char = line.find(" ")
        filepath = line[:first_empty_char]
        pkgs = line[last_empty_char + 1:].split(",")
        for pkg in pkgs:
            contents.setdefault(pkg[pkg.find("/") + 1:], []).append(filepath)
    state.filemap[arch] = contents

def _add_package(state, package):
    util.set_dict(
        state.packages,
        value = package,
        keys = (package["Architecture"], package["Package"], package["Version"]),
    )

    # https://www.debian.org/doc/debian-policy/ch-relationships.html#virtual-packages-provides
    if "Provides" in package:
        for virtual in version_constraint.parse_depends(package["Provides"]):
            providers = util.get_dict(
                state.virtual_packages,
                (package["Architecture"], virtual["name"]),
                [],
            )

            # If multiple versions of a package expose the same virtual package,
            # we should only keep a single reference for the one with greater
            # version.
            for (i, (provider, provided_version)) in enumerate(providers):
                if package["Package"] == provider["Package"] and (
                    virtual["version"] == provided_version
                ):
                    if version_constraint.relop(
                        package["Version"],
                        provider["Version"],
                        ">>",
                    ):
                        providers[i] = (package, virtual["version"])

                    # Return since we found the same package + version.
                    return

            # Otherwise, first time encountering package.
            providers.append((package, virtual["version"]))
            util.set_dict(
                state.virtual_packages,
                providers,
                (package["Architecture"], virtual["name"]),
            )

def _virtual_packages(state, name, arch, suites = None):
    all_providers = util.get_dict(state.virtual_packages, [arch, name], [])
    if not suites:
        return all_providers
    return [(pkg, v) for (pkg, v) in all_providers if pkg["Dist"] in suites]

def _package_versions(state, name, arch, suites = None):
    all_packages = util.get_dict(state.packages, [arch, name], {})
    if not suites:
        return all_packages.keys()
    return [v for v, pkg in all_packages.items() if pkg["Dist"] in suites]

def _package(state, name, version, arch, suites = None):
    if not version:
        return None
    package = util.get_dict(state.packages, keys = (arch, name, version))
    if not package:
        return None
    if suites and package["Dist"] not in suites:
        return None
    return package

def _filemap(state, name, arch):
    if arch not in state.filemap:
        return None
    all = state.filemap[arch]
    if name not in all:
        return None
    return state.filemap[arch][name]

def _add_source_if_not_present(state, source):
    (urls, dist, components, architectures) = source

    for arch in architectures:
        for comp in components:
            keys = [
                "%".join((url, dist, comp, arch))
                for url in urls
            ]
            found = any([
                key in state.sources
                for key in keys
            ])
            if found:
                continue
            for key in keys:
                state.sources[key] = (urls, dist, comp, arch)

def _create():
    state = struct(
        sources = dict(),
        filemap = dict(),
        packages = dict(),
        virtual_packages = dict(),
    )

    return struct(
        add_source = lambda source: _add_source_if_not_present(state, source),
        sources = lambda: state.sources,
        parse_package_index = lambda contents, roots, dist: _parse_repository(state, contents, roots, dist),
        parse_contents = lambda rcontents, arch: _parse_contents(state, rcontents, arch),
        package_versions = lambda **kwargs: _package_versions(state, **kwargs),
        virtual_packages = lambda **kwargs: _virtual_packages(state, **kwargs),
        package = lambda **kwargs: _package(state, **kwargs),
        filemap = lambda **kwargs: _filemap(state, **kwargs),
    )

deb_repository = struct(
    new = _create,
)

# TESTONLY: DO NOT DEPEND ON THIS
def _create_test_only():
    state = struct(
        packages = dict(),
        virtual_packages = dict(),
    )

    def reset():
        state.packages.clear()
        state.virtual_packages.clear()

    return struct(
        package_versions = lambda **kwargs: _package_versions(state, **kwargs),
        virtual_packages = lambda **kwargs: _virtual_packages(state, **kwargs),
        package = lambda **kwargs: _package(state, **kwargs),
        parse_repository = lambda contents, dist = "test": _parse_repository(state, contents, "http://nowhere", dist),
        packages = state.packages,
        reset = reset,
    )

DO_NOT_DEPEND_ON_THIS_TEST_ONLY = struct(
    new = _create_test_only,
)
