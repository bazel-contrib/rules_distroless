"lock"

load(":util.bzl", "util")

def _make_package_key(name, version, arch):
    return "%s_%s_%s" % (
        util.sanitize(name),
        util.sanitize(version),
        arch,
    )

def _package_key(package, arch):
    return _make_package_key(package["Package"], package["Version"], arch)

def _add_package(lock, package, arch):
    k = _package_key(package, arch)
    if k in lock.fast_package_lookup:
        return
    lock.packages.append({
        "key": k,
        "name": package["Package"],
        "version": package["Version"],
        "urls": [
            "%s/%s" % (root, package["Filename"])
            for root in package["Roots"]
        ],
        "sha256": package["SHA256"],
        "arch": arch,
        "dependencies": [],
    })
    lock.fast_package_lookup[k] = len(lock.packages) - 1

def _add_package_dependency(lock, package, dependency, arch):
    k = _package_key(package, arch)
    if k not in lock.fast_package_lookup:
        fail("Broken state: %s is not in the lockfile." % package["Package"])
    i = lock.fast_package_lookup[k]
    lock.packages[i]["dependencies"].append(dict(
        key = _package_key(dependency, arch),
        name = dependency["Package"],
        version = dependency["Version"],
    ))

def _has_package(lock, name, version, arch):
    key = "%s_%s_%s" % (util.sanitize(name), util.sanitize(version), arch)
    return key in lock.fast_package_lookup

def _create(rctx, lock):
    return struct(
        has_package = lambda *args, **kwargs: _has_package(lock, *args, **kwargs),
        add_package = lambda *args, **kwargs: _add_package(lock, *args, **kwargs),
        add_package_dependency = lambda *args, **kwargs: _add_package_dependency(lock, *args, **kwargs),
        packages = lambda: lock.packages,
        write = lambda out: rctx.file(out, json.encode_indent(struct(version = lock.version, packages = lock.packages)), executable = False),
        as_json = lambda: json.encode_indent(struct(version = lock.version, packages = lock.packages)),
    )

def _empty(rctx):
    lock = struct(
        version = 1,
        packages = list(),
        fast_package_lookup = dict(),
    )
    return _create(rctx, lock)

def _from_json(rctx, content):
    if not content:
        return _empty(rctx)

    lock = json.decode(content)
    if lock["version"] != 1:
        fail("invalid lockfile version")

    lock = struct(
        version = lock["version"],
        packages = lock["packages"],
        fast_package_lookup = dict(),
    )
    for (i, package) in enumerate(lock.packages):
        # TODO: only support urls before 1.0
        if "url" in package:
            package["urls"] = [package.pop("url")]

        lock.packages[i] = package
        lock.fast_package_lookup[package["key"]] = i
    return _create(rctx, lock)

lockfile = struct(
    empty = _empty,
    from_json = _from_json,
    make_package_key = _make_package_key,
)
