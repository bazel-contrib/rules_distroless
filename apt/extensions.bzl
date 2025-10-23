"apt extensions"

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

def _distroless_extension(mctx):
    root_direct_deps = []
    root_direct_dev_deps = []
    reproducible = False

    # As in mach 9 :)
    glock = lockfile.merge(mctx, [
        lockfile.from_json(mctx, mctx.read(lock.into))
        for mod in mctx.modules
        for lock in mod.tags.lock
    ])

    repo = deb_repository.new(mctx, glock.facts())
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

    # Fetch all sources_list and parse them.
    # Unfortunately repository rules have no concept of threads
    # so parsing has to happen sequentially
    repo.fetch_and_parse()

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
                    ))

    for i in range(0, ITERATION_MAX + 1):
        if not len(resolution_queue):
            break
        if i == ITERATION_MAX:
            fail("apt.install exhausted, please file a bug")

        (dependency_set_name, name, version, arch) = resolution_queue.pop()

        mctx.report_progress("Resolving %s:%s" % (dep_constraint, arch))

        # TODO: Flattening approach of resolving dependencies has to change.
        (package, dependencies, unmet_dependencies, warnings) = resolver.resolve_all(
            name = name,
            version = version,
            arch = arch,
            include_transitive = install.include_transitive,
        )

        if not package:
            fail(
                "\n\nUnable to locate package `%s` for %s. It may only exist for specific set of architectures. \n" % (name, arch) +
                "   1 - Ensure that the package is available for the specified architecture. \n" +
                "   2 - Ensure that the specified version of the package is available for the specified architecture. \n" +
                "   3 - Ensure that an apt.source_list added for the specified architecture.",
            )

        for warning in warnings:
            util.warning(mctx, warning)

        if len(unmet_dependencies):
            util.warning(
                mctx,
                "Following dependencies could not be resolved for %s: %s" % (
                    name,
                    ",".join([up[0] for up in unmet_dependencies]),
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
    target_release = "noble",
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
        "target_release": attr.string(mandatory = True),
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
