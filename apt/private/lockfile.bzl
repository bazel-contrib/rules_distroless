"lock"

def _make_package_key(suite, name, version, arch):
    return "/%s/%s:%s=%s" % (
        suite,
        name,
        arch,
        version,
    )

def _short_package_key(package):
    return "/%s/%s:%s" % (
        package["Dist"],
        package["Package"],
        package["Architecture"],
    )

def _package_key(package):
    return _make_package_key(package["Dist"], package["Package"], package["Version"], package["Architecture"])

def _add_package(lock, package):
    k = _package_key(package)
    if k in lock.packages:
        return
    lock.packages[k] = {
        "name": package["Package"],
        "version": package["Version"],
        "architecture": package["Architecture"],
        "sha256": package["SHA256"],
        "filename": package["Filename"],
        "suite": package["Dist"],
        "size": int(package["Size"]),
        "depends_on": [],
    }

def _add_package_dependency(lock, package, dependency):
    k = _package_key(package)
    if k not in lock.packages:
        fail("illegal state: %s is not in the lockfile." % package["Package"])
    sk = _package_key(dependency)
    if sk in lock.packages[k]["depends_on"]:
        return
    lock.packages[k]["depends_on"].append(sk)

def _has_package(lock, suite, name, version, arch):
    return _make_package_key(suite, name, version, arch) in lock.packages

def _add_source(lock, suite, types, uris, components, architectures):
    lock.sources[suite] = {
        "types": types,
        "uris": uris,
        "components": components,
        "architectures": architectures,
    }

def _create(rctx, lock):
    return struct(
        has_package = lambda *args, **kwargs: _has_package(lock, *args, **kwargs),
        add_source = lambda *args, **kwargs: _add_source(lock, *args, **kwargs),
        add_package = lambda *args, **kwargs: _add_package(lock, *args, **kwargs),
        add_package_dependency = lambda *args, **kwargs: _add_package_dependency(lock, *args, **kwargs),
        packages = lambda: lock.packages,
        sources = lambda: lock.sources,
        dependency_sets = lambda: lock.dependency_sets,
        write = lambda out: rctx.file(out, _encode_compact(lock)),
        as_json = lambda: _encode_compact(lock),
    )

def _empty(rctx):
    lock = struct(
        version = 2,
        dependency_sets = dict(),
        packages = dict(),
        sources = dict(),
    )
    return _create(rctx, lock)

def _encode_compact(lock):
    return json.encode_indent(lock)

def _from_json(rctx, content):
    if not content:
        return _empty(rctx)

    lock = json.decode(content)
    if lock["version"] != 2:
        fail("lock file version %d is not supported anymore. please upgrade your lock file" % lock["version"])

    lock = struct(
        version = lock["version"],
        dependency_sets = lock["dependency_sets"] if "dependency_sets" in lock else dict(),
        packages = lock["packages"] if "packages" in lock else dict(),
        sources = lock["sources"] if "sources" in lock else dict(),
    )
    return _create(rctx, lock)

lockfile = struct(
    empty = _empty,
    from_json = _from_json,
    package_key = _package_key,
    short_package_key = _short_package_key,
)
