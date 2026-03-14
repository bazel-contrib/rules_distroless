"apt extensions"

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "read_netrc", "read_user_netrc", "use_netrc")
load("//apt/private:apt_deb_repository.bzl", "deb_repository")
load("//apt/private:apt_dep_resolver.bzl", "dependency_resolver")
load("//apt/private:deb_import.bzl", "deb_import")
load("//apt/private:lockfile.bzl", "lockfile")
load("//apt/private:translate_dependency_set.bzl", "translate_dependency_set")
load("//apt/private:util.bzl", "util")
load("//apt/private:version_constraint.bzl", "version_constraint")

# https://wiki.debian.org/SupportedArchitectures
ALL_SUPPORTED_ARCHES = ["armel", "armhf", "arm64", "i386", "amd64", "mips64el", "ppc64el", "x390x"]

ITERATION_MAX = 2147483646

def _parse_source(src):
    parts = src.split(" ")
    kind = parts.pop(0)
    if parts[0].startswith("["):
        # skip arch for now.
        arch = parts.pop(0)
    url = parts.pop(0)
    dist = parts.pop(0)
    components = parts
    return struct(
        kind = kind,
        url = url,
        dist = dist,
        components = components,
    )

def _get_auth(mctx, urls):
    """Given the list of URLs obtain the correct auth dict."""
    if "NETRC" in mctx.os.environ:
        netrc = read_netrc(mctx, mctx.os.environ["NETRC"])
    else:
        netrc = read_user_netrc(mctx)
    return use_netrc(netrc, urls, {})

def _start_downloads(mctx, urls, dist, comp, arch, integrity, index_type, cached_format = None):
    """Initiate all format downloads for a given index type with block=False.

    If cached_format is set, only that extension is attempted — avoiding
    404 warnings for formats the remote doesn't serve.
    """
    target_triple = "{}/{}/{}".format(dist, comp, arch)

    # See https://linux.die.net/man/1/xz , https://linux.die.net/man/1/gzip , and https://linux.die.net/man/1/bzip2
    #  --keep       -> keep the original file (Bazel might be still committing the output to the cache)
    #  --force      -> overwrite the output if it exists
    #  --decompress -> decompress
    # Order of these matter, we want to try the one that is most likely first.
    if index_type == "Packages":
        extensions = [
            (".xz", ["xz", "--decompress", "--keep", "--force"]),
            (".gz", ["gzip", "--decompress", "--keep", "--force"]),
            (".bz2", ["bzip2", "--decompress", "--keep", "--force"]),
            ("", ["true"]),
        ]
    else:
        extensions = [
            (".gz", ["gzip", "--decompress", "--keep", "--force"]),
            (".xz", ["xz", "--decompress", "--keep", "--force"]),
            (".bz2", ["bzip2", "--decompress", "--keep", "--force"]),
            ("", ["true"]),
        ]

    if cached_format != None:
        extensions = [(ext, cmd) for (ext, cmd) in extensions if ext == cached_format]

    base_auth = _get_auth(mctx, urls)
    tokens = []
    for (url_idx, url) in enumerate(urls):
        for (ext, cmd) in extensions:
            # Each (url, ext) gets a unique output directory to prevent
            # concurrent downloads from clobbering each other's files.
            # Without this, the uncompressed variant ("") and a decompressed
            # .xz/.gz/.bz2 would both write to the same final path.
            ext_name = ext.lstrip(".") if ext else "raw"
            output = "{}/{}/{}/{}{}".format(target_triple, url_idx, ext_name, index_type, ext)
            if index_type == "Packages":
                dist_url = "{}/dists/{}/{}/binary-{}/{}{}".format(url, dist, comp, arch, index_type, ext)
            else:
                dist_url = "{}/dists/{}/{}/Contents-{}{}".format(url, dist, comp, arch, ext)
            auth = {}
            if url in base_auth:
                auth = {dist_url: base_auth[url]}
            token = mctx.download(
                url = dist_url,
                output = output,
                integrity = integrity,
                allow_fail = True,
                auth = auth,
                block = False,
            )
            tokens.append((ext, cmd, url, url_idx, ext_name, output, token))
    return tokens

def _resolve_downloads(mctx, tokens, index_type, dist, comp, arch):
    """Wait on tokens in priority order, decompress the first success.

    Returns (output_path, url, integrity, ext) on success.
    Returns None for optional Contents when all attempts fail.
    """
    failed_attempts = []
    for (ext, cmd, url, url_idx, ext_name, output, token) in tokens:
        download = token.wait()
        decompress_r = None
        if download.success:
            decompress_r = mctx.execute(cmd + [output])
            if decompress_r.return_code == 0:
                target_triple = "{}/{}/{}".format(dist, comp, arch)

                # Decompressed file lives in its own ext_name subdirectory
                return ("{}/{}/{}/{}".format(target_triple, url_idx, ext_name, index_type), url, download.integrity, ext)
        failed_attempts.append((url + "/.../" + index_type + ext, download, decompress_r))

    if index_type == "Contents":
        # Contents files are optional; some repositories (e.g. packages.cloud.google.com/apt)
        # don't provide them. Print a warning and return None instead of failing.
        print("Warning: Could not fetch Contents index for {}/{}/{}. Contents files are optional.".format(dist, comp, arch))
        return None

    # For Packages, fail with details
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

def _fetch_and_parse_sources(mctx, repo, glock, snapshot_suites, formats):
    """Fetch all package indices and contents in parallel, then parse them."""
    pending = []
    seen = {}
    for source_key, source in repo.sources().items():
        (urls, dist, component, architecture) = source

        # Deduplicate: multiple dict entries can map to the same logical source
        # (one entry per URL in the urls list). Only process each unique
        # (dist, component, architecture) combination once.
        dedup_key = "{}/{}/{}".format(dist, component, architecture)
        if dedup_key in seen:
            continue
        seen[dedup_key] = True

        # We assume that `url` does not contain a trailing forward slash when passing to
        # functions below. If one is present, remove it. Some HTTP servers do not handle
        # redirects properly when a path contains "//"
        urls = [url.rstrip("/") for url in urls]

        pkg_fact_key = dist + "/" + component + "/" + architecture + "/Packages"
        cnt_fact_key = dist + "/" + component + "/" + architecture + "/Contents"

        # Check cached format info to avoid 404 warnings on subsequent runs
        cached_pkg_format = formats.get(pkg_fact_key)
        cached_cnt_format = formats.get(cnt_fact_key)

        # Pass 1: Initiate all downloads with block=False
        # For snapshot suites, integrity hashes from facts enable instant cache hits.
        # Cached formats narrow downloads to only the known-good extension.
        mctx.report_progress("starting downloads: {}/{} for {}".format(dist, component, architecture))
        pkg_tokens = _start_downloads(
            mctx,
            urls,
            dist,
            component,
            architecture,
            glock.facts().get(pkg_fact_key, ""),
            "Packages",
            cached_format = cached_pkg_format,
        )

        cnt_tokens = None
        if cached_cnt_format != "unavailable":
            cnt_tokens = _start_downloads(
                mctx,
                urls,
                dist,
                component,
                architecture,
                glock.facts().get(cnt_fact_key, ""),
                "Contents",
                cached_format = cached_cnt_format,
            )

        pending.append((
            urls,
            dist,
            component,
            architecture,
            pkg_tokens,
            cnt_tokens,
            pkg_fact_key,
            cnt_fact_key,
        ))

    # Pass 2: Wait, decompress, parse
    for (urls, dist, comp, arch, pkg_tokens, cnt_tokens, pkg_fk, cnt_fk) in pending:
        mctx.report_progress("resolving Package indices: {}/{} for {}".format(dist, comp, arch))
        (output, url, integrity, ext) = _resolve_downloads(mctx, pkg_tokens, "Packages", dist, comp, arch)
        if dist in snapshot_suites:
            glock.facts()[pkg_fk] = integrity
        formats[pkg_fk] = ext

        mctx.report_progress("parsing Package indices: {}/{} for {}".format(dist, comp, arch))
        repo.parse_package_index(mctx.read(output), urls, dist)

        if cnt_tokens != None:
            mctx.report_progress("resolving Contents: {}/{} for {}".format(dist, comp, arch))
            contents_result = _resolve_downloads(mctx, cnt_tokens, "Contents", dist, comp, arch)
        else:
            contents_result = None

        if contents_result != None:
            (output, url, integrity, ext) = contents_result
            if dist in snapshot_suites:
                glock.facts()[cnt_fk] = integrity
            formats[cnt_fk] = ext

            mctx.report_progress("parsing Contents: {}/{} for {}".format(dist, comp, arch))
            repo.parse_contents(mctx.read(output), arch)
        else:
            formats[cnt_fk] = "unavailable"

def _distroless_extension(mctx):
    root_direct_deps = []
    root_direct_dev_deps = []
    reproducible = False

    # Detect facts API availability
    use_facts = hasattr(mctx, "facts")
    cached_facts = mctx.facts if use_facts else {}

    # Seed glock from facts or lockfile
    if use_facts:
        glock = lockfile.empty(mctx)
        for (k, v) in cached_facts.get("indices", {}).items():
            glock.facts()[k] = v
    else:
        # as-in-mach 9
        glock = lockfile.merge(mctx, [
            lockfile.from_json(mctx, mctx.read(lock.into))
            for mod in mctx.modules
            for lock in mod.tags.lock
        ])

    # First pass over sources_list: classify suites as snapshot or rolling
    snapshot_suites = {}
    for mod in mctx.modules:
        for sl in mod.tags.sources_list:
            uris = [uri.removeprefix("mirror+") for uri in sl.uris]
            is_snapshot = len(uris) > 0 and all([util.is_snapshot_uri(uri) for uri in uris])
            if is_snapshot:
                for suite in sl.suites:
                    snapshot_suites[suite] = True

    repo = deb_repository.new()
    resolver = dependency_resolver.new(repo)

    for mod in mctx.modules:
        # TODO: also enfore that every module explicitly lists their sources_list
        # otherwise they'll break if the sources_list that the module depends on
        # magically disappears.
        for sl in mod.tags.sources_list:
            uris = [uri.removeprefix("mirror+") for uri in sl.uris]
            architectures = sl.architectures

            for suite in sl.suites:
                glock.add_source(
                    suite,
                    uris = uris,
                    types = sl.types,
                    components = sl.components,
                    architectures = architectures,
                )

                repo.add_source(
                    (uris, suite, sl.components, architectures),
                )

    # Seed cached formats from facts (which extensions each remote serves)
    formats = dict(cached_facts.get("formats", {}))

    # Fetch all sources_list in parallel and parse them.
    _fetch_and_parse_sources(mctx, repo, glock, snapshot_suites, formats)

    sources = glock.sources()
    dependency_sets = glock.dependency_sets()

    resolution_queue = []
    already_resolved = {}

    for mod in mctx.modules:
        for install in mod.tags.install:
            for dep_constraint in install.packages:
                constraint = version_constraint.parse_dep(dep_constraint)
                architectures = constraint["arch"]
                if not architectures:
                    # For cases where architecture for the package is not specified we need
                    # to first find out which source contains the package. in order to do
                    # that we first need to resolve the package for amd64 architecture.
                    # Once the repository is found, then resolve the package for all the
                    # architectures the repository supports.
                    (package, warning) = resolver.resolve_package(
                        name = constraint["name"],
                        version = constraint["version"],
                        arch = "amd64",
                        suites = install.suites,
                    )
                    if warning:
                        util.warning(mctx, warning)

                    # If the package is not found then add the package
                    # to the resolution_queue to let the resolver handle
                    # the error messages.
                    if not package:
                        resolution_queue.append((
                            install.dependency_set,
                            constraint["name"],
                            constraint["version"],
                            "amd64",
                            install.suites,
                        ))
                        continue

                    source = sources[package["Dist"]]
                    architectures = source["architectures"]

                for arch in architectures:
                    resolution_queue.append((
                        install.dependency_set,
                        constraint["name"],
                        constraint["version"],
                        arch,
                        install.suites,
                    ))

    for i in range(0, ITERATION_MAX + 1):
        if not len(resolution_queue):
            break
        if i == ITERATION_MAX:
            fail("apt.install exhausted, please file a bug")

        (dependency_set_name, name, version, arch, suites) = resolution_queue.pop()

        mctx.report_progress("Resolving %s:%s" % (name, arch))

        # TODO: Flattening approach of resolving dependencies has to change.
        (package, dependencies, unmet_dependencies, warnings) = resolver.resolve_all(
            name = name,
            version = version,
            arch = arch,
            include_transitive = True,
            suites = suites,
        )

        if not package:
            suite_msg = " in suite(s) [%s]" % ", ".join(suites) if suites else ""
            fail(
                "\n\nUnable to locate package `%s` for %s%s. It may only exist for specific set of architectures or suites. \n" % (name, arch, suite_msg) +
                "   1 - Ensure that the package is available for the specified architecture. \n" +
                "   2 - Ensure that the specified version of the package is available for the specified architecture. \n" +
                "   3 - Ensure that an apt.sources_list is added for the specified architecture.\n" +
                "   4 - If using suite constraints, ensure the package exists in the specified suite(s).",
            )

        for warning in warnings:
            util.warning(mctx, warning)

        if len(unmet_dependencies):
            util.warning(
                mctx,
                "Following dependencies could not be resolved for %s: %s (dependency set %s)" % (
                    name,
                    ",".join([up[0] for up in unmet_dependencies]),
                    dependency_set_name,
                ),
            )

        # TODO:
        # Ensure following statements are true.
        #  1- Package was resolved from a source that module listed explicitly.
        #  2- Package resolution was skipped because some other module asked for this package.
        #  3- 1) is enforced even if 2) is the case.
        glock.add_package(package)

        pkg_short_key = lockfile.short_package_key(package)

        already_resolved[pkg_short_key] = True

        for dep in dependencies:
            glock.add_package(dep)
            dep_key = lockfile.short_package_key(dep)
            if dep_key not in already_resolved:
                resolution_queue.append((
                    None,
                    dep["Package"],
                    ("=", dep["Version"]),
                    arch,
                    suites,
                ))
            glock.add_package_dependency(package, dep)

        # Add it to dependency set
        if dependency_set_name:
            dependency_set = dependency_sets.setdefault(dependency_set_name, {
                "sets": {},
            })
            arch_set = dependency_set["sets"].setdefault(arch, {})
            arch_set[pkg_short_key] = package["Version"]

    # Generate a hub repo for every dependency set
    lock_content = glock.as_json()
    for depset_name in dependency_sets.keys():
        translate_dependency_set(
            name = depset_name,
            depset_name = depset_name,
            lock_content = lock_content,
        )

    # Generate a repo per package which will be aliased by hub repo.
    for (package_key, package) in glock.packages().items():
        filemap = {}
        for key in package["depends_on"]:
            (suite, name, arch, version) = lockfile.parse_package_key(key)
            filemap[name] = repo.filemap(
                name = name,
                arch = arch,
            )

        deb_import(
            name = util.sanitize(package_key),
            target_name = util.sanitize(package_key),
            urls = [
                uri + "/" + package["filename"]
                for uri in sources[package["suite"]]["uris"]
            ],
            sha256 = package["sha256"],
            mergedusr = False,
            depends_on = package["depends_on"],
            depends_file_map = json.encode(filemap),
            package_name = package["name"],
        )

    if not use_facts:
        for mod in mctx.modules:
            if not mod.is_root:
                continue

            if len(mod.tags.lock) > 1:
                fail("There can only be one apt.lock per module.")
            elif len(mod.tags.lock) == 1:
                lock = mod.tags.lock[0]
                lock_tmp = mctx.path("apt.lock.json")
                glock.write(lock_tmp)
                lockf_wksp = mctx.path(lock.into)
                mctx.execute(
                    ["cp", "-f", lock_tmp, lockf_wksp],
                )

    if use_facts:
        filtered_indices = {
            k: v
            for k, v in glock.facts().items()
            if k.split("/")[0] in snapshot_suites
        }
        return mctx.extension_metadata(
            facts = {"indices": filtered_indices, "formats": formats},
        )

_doc = """
Module extension to create Debian repositories.

Create Debian repositories with packages "installed" in them and available
to use in Bazel.


Here's an example how to create a Debian repo:

```starlark
apt = use_extension("@rules_distroless//apt:extensions.bzl", "apt")
apt.sources_list(
    types = ["deb"],
    uris = [
        "https://snapshot.ubuntu.com/ubuntu/20240301T030400Z",
        "mirror+https://snapshot.ubuntu.com/ubuntu/20240301T030400Z"
    ],
    suites = ["noble", "noble-security", "noble-updates"],
    components = ["main"],
    architectures = ["all"]
)
apt.install(
    # dependency set isolates these installs into their own scope.
    dependency_set = "noble",
    suites = ["noble", "noble-security", "noble-updates"],
    packages = [
        "ncurses-base",
        "libncurses6",
        "tzdata",
        "coreutils:arm64",
        "libstdc++6:i386"
    ]
)
```


`apt.install` will install generate a package repository for each package and architecture
combination in the form of `@<TARGET_RELEASE>_<PKG_NAME>_<PKG_ARCH>`.

Each `<PACKAGE>/<ARCH>` has two targets that match the usual structure of a
Debian package: `data` and `control`.

You can use the package like so: `@<REPO>//<PACKAGE>/<ARCH>:<TARGET>`.

E.g. for the previous example, you could use `@bullseye//perl/amd64:data`.

### Lockfiles

As mentioned, the macro can be used without a lock because the lock will be
generated internally on-demand. However, this comes with the cost of
performing a new package resolution on repository cache misses.

The lockfile can be generated by running `bazel run @bullseye//:lock`. This
will generate a `.lock.json` file of the same name and in the same path as
the YAML `manifest` file.

If you explicitly want to run without a lock and avoid the warning messages
set the `nolock` argument to `True`.

### Best Practice: use snapshot archive URLs

While we strongly encourage users to check in the generated lockfile, it's
not always possible because Debian repositories are rolling by default.
Therefore, a lockfile generated today might not work later if the upstream
repository removes or publishes a new version of a package.

To avoid this problems and increase the reproducibility it's recommended to
avoid using normal Debian mirrors and use snapshot archives instead.

Snapshot archives provide a way to access Debian package mirrors at a point
in time. Basically, it's a "wayback machine" that allows access to (almost)
all past and current packages based on dates and version numbers.

Debian has had snapshot archives for [10+
years](https://lists.debian.org/debian-announce/2010/msg00002.html). Ubuntu
began providing a similar service recently and has packages available since
March 1st 2023.

To use this services simply use a snapshot URL in the manifest. Here's two
examples showing how to do this for Debian and Ubuntu:
  * [/examples/debian_snapshot](/examples/debian_snapshot)
  * [/examples/ubuntu_snapshot](/examples/ubuntu_snapshot)

For more infomation, please check https://snapshot.debian.org and/or
https://snapshot.ubuntu.com.
"""

sources_list = tag_class(
    attrs = {
        "sources": attr.string_list(
            # mandatory = True,
        ),
        "types": attr.string_list(),
        "uris": attr.string_list(),
        "suites": attr.string_list(),
        "components": attr.string_list(),
        "architectures": attr.string_list(),
    },
)

install = tag_class(
    attrs = {
        "packages": attr.string_list(
            mandatory = True,
            allow_empty = False,
        ),
        "dependency_set": attr.string(),
        "suites": attr.string_list(),
        "include_transitive": attr.bool(default = True),
    },
)

lock = tag_class(
    attrs = {
        "into": attr.label(
            mandatory = True,
        ),
    },
)

apt = module_extension(
    doc = _doc,
    implementation = _distroless_extension,
    tag_classes = {
        "install": install,
        "sources_list": sources_list,
        "lock": lock,
    },
)
