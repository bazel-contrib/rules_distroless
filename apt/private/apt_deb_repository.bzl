"https://wiki.debian.org/DebianRepository"

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "read_netrc", "read_user_netrc", "use_netrc")
load(":util.bzl", "util")
load(":version_constraint.bzl", "version_constraint")

def _get_auth(ctx, urls):
    """Given the list of URLs obtain the correct auth dict."""
    if "NETRC" in ctx.os.environ:
        netrc = read_netrc(ctx, ctx.os.environ["NETRC"])
    else:
        netrc = read_user_netrc(ctx)
    return use_netrc(netrc, urls, {})

def _fetch_package_index(mctx, urls, dist, comp, arch, integrity):
    target_triple = "{dist}/{comp}/{arch}".format(dist = dist, comp = comp, arch = arch)

    # See https://linux.die.net/man/1/xz , https://linux.die.net/man/1/gzip , and https://linux.die.net/man/1/bzip2
    #  --keep       -> keep the original file (Bazel might be still committing the output to the cache)
    #  --force      -> overwrite the output if it exists
    #  --decompress -> decompress
    # Order of these matter, we want to try the one that is most likely first.
    supported_extensions = [
        (".xz", ["xz", "--decompress", "--keep", "--force"]),
        (".gz", ["gzip", "--decompress", "--keep", "--force"]),
        (".bz2", ["bzip2", "--decompress", "--keep", "--force"]),
        ("", ["true"]),
    ]

    failed_attempts = []

    url = None
    base_auth = _get_auth(mctx, urls)
    for url in urls:
        download = None
        for (ext, cmd) in supported_extensions:
            output = "{}/Packages{}".format(target_triple, ext)
            dist_url = "{}/dists/{}/{}/binary-{}/Packages{}".format(url, dist, comp, arch, ext)
            auth = {}
            if url in base_auth:
                auth = {dist_url: base_auth[url]}
            download = mctx.download(
                url = dist_url,
                output = output,
                integrity = integrity,
                allow_fail = True,
                auth = auth,
            )
            decompress_r = None
            if download.success:
                decompress_r = mctx.execute(cmd + [output])
                if decompress_r.return_code == 0:
                    integrity = download.integrity
                    break

            failed_attempts.append((dist_url, download, decompress_r))

        if download.success:
            break

    if len(failed_attempts) == len(supported_extensions) * len(urls):
        attempt_messages = []
        for (failed_url, download, decompress) in failed_attempts:
            reason = "unknown"
            if not download.success:
                reason = "Download failed. See warning above for details."
            elif decompress.return_code != 0:
                reason = "Decompression failed with non-zero exit code.\n\n{}\n{}".format(decompress.stderr, decompress.stdout)

            attempt_messages.append("""\n*) Failed '{}'\n\n{}""".format(failed_url, reason))

        fail("""
** Tried to download {} different package indices and all failed.

{}
        """.format(len(failed_attempts), "\n".join(attempt_messages)))

    return ("{}/Packages".format(target_triple), url, integrity)

def _fetch_contents(mctx, urls, dist, comp, arch, integrity):
    target_triple = "{dist}/{comp}/{arch}".format(dist = dist, comp = comp, arch = arch)

    # See https://linux.die.net/man/1/xz , https://linux.die.net/man/1/gzip , and https://linux.die.net/man/1/bzip2
    #  --keep       -> keep the original file (Bazel might be still committing the output to the cache)
    #  --force      -> overwrite the output if it exists
    #  --decompress -> decompress
    # Order of these matter, we want to try the one that is most likely first.
    supported_extensions = [
        (".gz", ["gzip", "--decompress", "--keep", "--force"]),
        (".xz", ["xz", "--decompress", "--keep", "--force"]),
        (".bz2", ["bzip2", "--decompress", "--keep", "--force"]),
        ("", ["true"]),
    ]

    failed_attempts = []

    url = None
    base_auth = _get_auth(mctx, urls)
    for url in urls:
        download = None
        for (ext, cmd) in supported_extensions:
            output = "{}/Contents{}".format(target_triple, ext)
            dist_url = "{}/dists/{}/{}/Contents-{}{}".format(url, dist, comp, arch, ext)
            auth = {}
            if url in base_auth:
                auth = {dist_url: base_auth[url]}
            download = mctx.download(
                url = dist_url,
                output = output,
                integrity = integrity,
                allow_fail = True,
                auth = auth,
            )
            decompress_r = None
            if download.success:
                decompress_r = mctx.execute(cmd + [output])
                if decompress_r.return_code == 0:
                    integrity = download.integrity
                    break

            failed_attempts.append((dist_url, download, decompress_r))

        if download.success:
            break

    if len(failed_attempts) == len(supported_extensions) * len(urls):
        attempt_messages = []
        for (failed_url, download, decompress) in failed_attempts:
            reason = "unknown"
            if not download.success:
                reason = "Download failed. See warning above for details."
            elif decompress.return_code != 0:
                reason = "Decompression failed with non-zero exit code.\n\n{}\n{}".format(decompress.stderr, decompress.stdout)

            attempt_messages.append("""\n*) Failed '{}'\n\n{}""".format(failed_url, reason))

        fail("""
** Tried to download {} different package indices and all failed.

{}
        """.format(len(failed_attempts), "\n".join(attempt_messages)))

    return ("{}/Contents".format(target_triple), url, integrity)

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

def _virtual_packages(state, name, arch):
    return util.get_dict(state.virtual_packages, [arch, name], [])

def _package_versions(state, name, arch):
    return util.get_dict(state.packages, [arch, name], {}).keys()

def _package(state, name, version, arch):
    return util.get_dict(state.packages, keys = (arch, name, version))

def _filemap(state, name, arch):
    if arch not in state.filemap:
        return None
    all = state.filemap[arch]
    if name not in all:
        return None
    return state.filemap[arch][name]

def _fetch_and_parse_sources(state):
    mctx = state.mctx
    facts = state.facts

    # TODO: make parallel
    for source in state.sources.values():
        (urls, dist, component, architecture) = source

        # We assume that `url` does not contain a trailing forward slash when passing to
        # functions below. If one is present, remove it. Some HTTP servers do not handle
        # redirects properly when a path contains "//"
        # (ie. https://mymirror.com/ubuntu//dists/noble/stable/... may return a 404
        # on misconfigured HTTP servers)
        urls = [url.rstrip("/") for url in urls]

        fact_key = dist + "/" + component + "/" + architecture + "/Packages"

        mctx.report_progress("fetching Package indices: {}/{} for {}".format(dist, component, architecture))
        (output, url, integrity) = _fetch_package_index(mctx, urls, dist, component, architecture, facts.get(fact_key, ""))

        facts[fact_key] = integrity

        mctx.report_progress("parsing Package indices: {}/{} for {}".format(dist, component, architecture))
        _parse_repository(state, mctx.read(output), urls, dist)

        fact_key = dist + "/" + component + "/" + architecture + "/Contents"

        mctx.report_progress("fetching Contents: {}/{} for {}".format(dist, component, architecture))
        (output, url, integrity) = _fetch_contents(mctx, urls, dist, component, architecture, facts.get(fact_key, ""))

        facts[fact_key] = integrity

        mctx.report_progress("parsing Contents: {}/{} for {}".format(dist, component, architecture))
        _parse_contents(state, mctx.read(output), architecture)

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

def _create(mctx, facts):
    state = struct(
        mctx = mctx,
        sources = dict(),
        filemap = dict(),
        packages = dict(),
        virtual_packages = dict(),
        facts = facts,
    )

    return struct(
        add_source = lambda source: _add_source_if_not_present(state, source),
        fetch_and_parse = lambda: _fetch_and_parse_sources(state),
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
        parse_repository = lambda contents: _parse_repository(state, contents, "http://nowhere"),
        packages = state.packages,
        reset = reset,
    )

DO_NOT_DEPEND_ON_THIS_TEST_ONLY = struct(
    new = _create_test_only,
)
