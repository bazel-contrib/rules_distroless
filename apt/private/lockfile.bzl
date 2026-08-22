"lock"

def _make_package_key(suite, name, version, arch):
    return "/%s/%s:%s=%s" % (
        suite,
        name,
        arch,
        version,
    )

def _parse_package_key(key):
    rest = key[1:]
    (suite, rest) = rest.split("/", 1)
    (name, rest) = rest.split(":", 1)
    (arch, version) = rest.split("=", 1)
    return (suite, name, arch, version)

# `arch`, when set, overrides the package's own `Architecture` field for keying
# purposes. This is how `Architecture: all` packages are "expanded": the same
# package is keyed once per target architecture (e.g. `.../ucf:amd64` and
# `.../ucf:arm64`) so each can carry its own architecture-specific dependency
# closure.
def _short_package_key(package, arch = None):
    """Create a key for a given package.

    `arch`, when set, overrides the package's own `Architecture` field in the key.
    This is used to "expand" `Architecture: all` packages, to create one package per relevant architecture.
    This allows `Architecture: all` packages that depend on per-architecture packages (e.g. `/bullseye/ucf`)
    to create one dependency closure per architecture.
    """
    return "/%s/%s:%s" % (
        package["Dist"],
        package["Package"],
        arch or package["Architecture"],
    )

def _package_key(package, arch = None):
    return _make_package_key(package["Dist"], package["Package"], package["Version"], arch or package["Architecture"])

def _package_identity(name, arch):
    return "%s:%s" % (name, arch)

def _index_packages(packages):
    package_index = {}
    for package_key in packages:
        (_, name, arch, _) = _parse_package_key(package_key)
        identity = _package_identity(name, arch)
        if identity not in package_index:
            package_index[identity] = package_key
    return package_index

def _add_package(lock, package_index, package, arch = None):
    target_arch = arch or package["Architecture"]
    identity = _package_identity(package["Package"], target_arch)
    if identity in package_index:
        return
    k = _package_key(package, arch)
    lock.packages[k] = {
        "name": package["Package"],
        "version": package["Version"],
        "architecture": package["Architecture"],
        "sha256": package["SHA256"],
        "filename": package["Filename"],
        "suite": package["Dist"],
        "section": package["Section"],
        "size": int(package["Size"]),
        "depends_on": [],
    }
    package_index[identity] = k

def _add_package_dependency(lock, package_index, package, dependency, arch = None):
    target_arch = arch or package["Architecture"]
    k = package_index.get(_package_identity(package["Package"], target_arch))
    if not k:
        fail("illegal state: %s is not in the lockfile." % package["Package"])
    sk = package_index.get(_package_identity(dependency["Package"], target_arch))
    if not sk:
        fail("illegal state: %s is not in the lockfile." % dependency["Package"])
    if sk in lock.packages[k]["depends_on"]:
        return
    lock.packages[k]["depends_on"].append(sk)

def _has_package(lock, suite, name, version, arch):
    return _make_package_key(suite, name, version, arch) in lock.packages

def _add_source(lock, suite, types, uris, components, architectures):
    existing = lock.sources.get(suite)
    if existing:
        architectures = existing["architectures"] + [
            arch
            for arch in architectures
            if arch not in existing["architectures"]
        ]

    lock.sources[suite] = {
        "types": types,
        "uris": uris,
        "components": components,
        "architectures": architectures,
    }

def _create(mctx, lock):
    package_index = _index_packages(lock.packages)
    return struct(
        has_package = lambda *args, **kwargs: _has_package(lock, *args, **kwargs),
        add_source = lambda *args, **kwargs: _add_source(lock, *args, **kwargs),
        add_package = lambda *args, **kwargs: _add_package(lock, package_index, *args, **kwargs),
        add_package_dependency = lambda *args, **kwargs: _add_package_dependency(lock, package_index, *args, **kwargs),
        packages = lambda: lock.packages,
        sources = lambda: lock.sources,
        dependency_sets = lambda: lock.dependency_sets,
        facts = lambda: lock.facts,
        write = lambda out: mctx.file(out, _encode_compact(lock)),
        as_json = lambda: _encode_compact(lock),
    )

def _empty(mctx):
    lock = struct(
        version = 2,
        dependency_sets = dict(),
        packages = dict(),
        sources = dict(),
        facts = dict(),
    )
    return _create(mctx, lock)

def _encode_compact(lock):
    return json.encode_indent(lock)

def _from_json(mctx, content):
    if not content:
        return _empty(mctx)

    lock = json.decode(content)
    if lock["version"] != 2:
        fail("lock file version %d is not supported anymore. please upgrade your lock file" % lock["version"])

    lock = struct(
        version = lock["version"],
        dependency_sets = lock["dependency_sets"] if "dependency_sets" in lock else dict(),
        packages = lock["packages"] if "packages" in lock else dict(),
        sources = lock["sources"] if "sources" in lock else dict(),
        facts = lock["facts"] if "facts" in lock else dict(),
    )
    return _create(mctx, lock)

def _merge(mctx, locks):
    packages = {}
    facts = {}
    for lock in locks:
        for (key, pkg) in lock.packages().items():
            packages[key] = pkg
        for (key, fact) in lock.facts().items():
            facts[key] = fact
    return _create(mctx, struct(
        version = 2,
        dependency_sets = {},
        packages = packages,
        sources = {},
        facts = facts,
    ))

lockfile = struct(
    empty = _empty,
    from_json = _from_json,
    package_key = _package_key,
    short_package_key = _short_package_key,
    parse_package_key = _parse_package_key,
    merge = _merge,
)
