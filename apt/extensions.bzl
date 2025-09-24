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

    for mod in mctx.modules:
        lockf = lockfile.empty(mctx)

        # if mod.is_root:

        if len(mod.tags.lock):
            lock = mod.tags.lock[0]
            lockf = lockfile.from_json(mctx, mctx.read(lock.into))

        deb_repo = deb_repository.new(mctx, lockf.facts())
        resolver = dependency_resolver.new(deb_repo)

        for sl in mod.tags.sources_list:
            continue
            uris = [uri.removeprefix("mirror+") for uri in sl.uris]
            architectures = sl.architectures

            for suite in sl.suites:
                lockf.add_source(
                    suite,
                    uris = uris,
                    types = sl.types,
                    components = sl.components,
                    architectures = architectures,
                )
                deb_repo.add_source(
                    (uris, suite, sl.components, architectures),
                )

        deb_repo.fetch_and_parse()

        sources = lockf.sources()
        dependency_sets = lockf.dependency_sets()
        for install in mod.tags.install:
            continue
            dependency_set = dependency_sets.setdefault(install.dependency_set, {
                "sets": {},
            })
            for dep_constraint in install.packages:
                constraint = version_constraint.parse_dep(dep_constraint)

                architectures = []

                if constraint["arch"]:
                    architectures = constraint["arch"]
                else:
                    architectures = ["amd64"]

                for _ in range(len(ALL_SUPPORTED_ARCHES)):
                    if len(architectures) == 0:
                        break
                    arch = architectures.pop()
                    resolved_count = 0

                    mctx.report_progress("Resolving %s:%s" % (dep_constraint, arch))
                    (package, dependencies, unmet_dependencies, warnings) = resolver.resolve_all(
                        name = constraint["name"],
                        version = constraint["version"],
                        arch = arch,
                        include_transitive = install.include_transitive,
                    )

                    if not package:
                        fail(
                            "\n\nUnable to locate package `%s` for %s. It may only exist for specific set of architectures. \n" % (dep_constraint, arch) +
                            "   1 - Ensure that the package is available for the specified architecture. \n" +
                            "   2 - Ensure that the specified version of the package is available for the specified architecture. \n" +
                            "   3 - Ensure that an apt.source_list added for the specified architecture.",
                        )

                    for warning in warnings:
                        util.warning(mctx, warning)

                    if len(unmet_dependencies):
                        util.warning(mctx, "Following dependencies could not be resolved for %s: %s" % (constraint["name"], ",".join([up[0] for up in unmet_dependencies])))

                    lockf.add_package(package)

                    resolved_count += len(dependencies) + 1

                    for dep in dependencies:
                        lockf.add_package(dep)
                        lockf.add_package_dependency(package, dep)

                    # Add it to dependency set
                    arch_set = dependency_set["sets"].setdefault(arch, {})
                    arch_set[lockfile.short_package_key(package)] = package["Version"]

                    # For cases where architecture for the package is not specified we need
                    # to first find out which source contains the package. in order to do
                    # that we first need to resolve the package for amd64 architecture.
                    # Once the repository is found, then resolve the package for all the
                    # architectures the repository supports.
                    if not constraint["arch"] and arch == "amd64":
                        source = sources[package["Dist"]]
                        architectures = [a for a in source["architectures"] if a != "amd64"]

                mctx.report_progress("Resolved %d packages for %s" % (resolved_count, arch))

        # Generate a hub repo for every dependency set
        lock_content = lockf.as_json()
        for depset_name in dependency_sets.keys():
            translate_dependency_set(
                name = depset_name,
                depset_name = depset_name,
                lock_content = lock_content,
            )

        # Generate a repo per package which will be aliased by hub repo.
        for (package_key, package) in lockf.packages().items():
            # dependent_packages = None
            # if package["name"].endswith("-dev")
            #     packages = lockf.packages()
            #     dependent_packages = json.encode([

            #     ])

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
                package_name = package["name"],
            )

        for lock in mod.tags.lock:
            lock_tmp = mctx.path("apt.lock.json")
            lockf.write(lock_tmp)
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
