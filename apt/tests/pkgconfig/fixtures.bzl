"""Existing Debian packages used by the pkg-config export regression tests."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
load("//apt/private:deb_filemap.bzl", "deb_filemap")
load("//apt/private:deb_import.bzl", "deb_import")
load("//apt/private:translate_dependency_set.bzl", "translate_dependency_set")
load("//apt/private:util.bzl", "util")

_PACKAGES = {
    "liblua5.4-dev": ("l/lua5.4", "5.4.4-3+deb12u1", {
        "amd64": "f02e06d3598de40a1df51ea4144668a1c6acb8813d4647a6d89cca0d256179d3",
        "arm64": "d129cf46974ea27cff43626924214af9ff9c60df40090d817c6962579487d531",
    }),
    "liblua5.4-0": ("l/lua5.4", "5.4.4-3+deb12u1", {
        "amd64": "b042e78d02dd8457cf7de253ae89992e50050f450d9bec66843ffb1a14ab23c7",
        "arm64": "575e824c21715038d8c1c62a6dcd8bfe5e3027367513568fe87d9d81a85ffef4",
    }),
    "zlib1g-dev": ("z/zlib", "1.2.11.dfsg-2+deb11u2", {
        "amd64": "f49fc849870c4e64fed2794722841ee950c1788f7fe90b3a091e6a098a46cd33",
        "arm64": "6aa99970b3af7dbc6e34d7b55b493ba65b1a2d7c18cea042e96e271f1bb8ecfe",
    }),
    "zlib1g": ("z/zlib", "1.2.11.dfsg-2+deb11u2", {
        "amd64": "03d2ab2174af76df6f517b854b77460fbdafc3dac0dca979317da67538159a3e",
        "arm64": "e3963985d1a020d67ffd4180e6f9c4b5c600b515f0c9d8fda513d7a0e48e63a1",
    }),
    "xtrans-dev": ("x/xtrans", "1.4.0-1", {
        "all": "9ce1af9464faee0c679348dd11cdf63934c12e734a64e0903692b0cb5af38e06",
    }),
}

_MULTIARCH = {"amd64": "x86_64-linux-gnu", "arm64": "aarch64-linux-gnu"}

def _key(package, architecture):
    return "/pkgconfig_test/{}:{}={}".format(package, architecture, _PACKAGES[package][1])

def fixture_repo(package, architecture, mergedusr = False):
    """Return the repository label prefix for a pinned package fixture."""
    return "@" + util.package_repo_name(_key(package, architecture), mergedusr = mergedusr)

def _fixtures_impl(module_ctx):
    packages = {}
    sets = {"amd64": {}, "arm64": {}}
    for package, (directory, version, hashes) in _PACKAGES.items():
        for architecture, sha256 in hashes.items():
            key = _key(package, architecture)
            urls = ["https://deb.debian.org/debian/pool/main/{}/{}_{}_{}.deb".format(directory, package, version, architecture)]
            depends_on = []
            if package == "liblua5.4-dev":
                # Model a lockfile's combined dependency closure: both CPU
                # variants plus an Architecture: all metadata dependency.
                depends_on = [
                    _key(dep, arch)
                    for dep in ["liblua5.4-0", "zlib1g-dev", "zlib1g"]
                    for arch in _MULTIARCH
                ] + [_key("xtrans-dev", "all")]
            elif package == "zlib1g-dev":
                depends_on = [_key("zlib1g", architecture)]
            packages[key] = {
                "name": package,
                "version": version,
                "architecture": architecture,
                "suite": "pkgconfig_test",
                "sha256": sha256,
                "urls": urls,
                "depends_on": depends_on,
            }
            for arch in _MULTIARCH:
                if architecture in [arch, "all"]:
                    sets[arch][key.split("=")[0]] = version

            # Keep the downloaded .deb as the independent byte oracle. These
            # fixtures only import published packages; they never build .debs.
            if package.endswith("-dev"):
                http_file(
                    name = "pkgconfig_original_{}_{}".format(package, architecture),
                    urls = urls,
                    sha256 = sha256,
                    downloaded_file_path = "package.deb",
                )

            for mergedusr in [False, True]:
                repository = util.package_repo_name(key, mergedusr = mergedusr)
                files = []
                if package == "liblua5.4-0":
                    files = [
                        "usr/lib/{}/{}.so.0.0.0".format(_MULTIARCH[architecture], library)
                        for library in ["liblua5.4", "liblua5.4-c++"]
                    ]
                elif package == "zlib1g":
                    files = ["lib/{}/libz.so.1.2.11".format(_MULTIARCH[architecture])]
                deb_filemap(name = repository + "_filemap", files = json.encode(files))
                runtime = {"liblua5.4-dev": "liblua5.4-0", "zlib1g-dev": "zlib1g"}.get(package)
                runtime_keys = [_key(runtime, architecture)] if runtime else []
                deb_import(
                    name = repository,
                    package_name = package,
                    target_name = repository,
                    urls = urls,
                    sha256 = sha256,
                    mergedusr = mergedusr,
                    depends_on = runtime_keys,
                    dep_filemaps = [
                        "@" + util.package_repo_name(dep, mergedusr = mergedusr) + "_filemap//:filemap.json"
                        for dep in runtime_keys
                    ],
                )

    lock = json.encode({
        "version": 2,
        "packages": packages,
        "dependency_sets": {"test": {"sets": sets}},
    })
    for mergedusr in [False, True]:
        translate_dependency_set(
            name = "pkgconfig_packages" + ("_mergedusr" if mergedusr else ""),
            depset_name = "test",
            lock_content = lock,
            mergedusr = mergedusr,
        )
    translate_dependency_set(
        name = "pkgconfig_custom_template",
        depset_name = "test",
        lock_content = lock,
        package_template = "//apt/tests/pkgconfig:legacy.BUILD.tmpl",
    )
    translate_dependency_set(
        name = "pkgconfig_empty",
        depset_name = "test",
        lock_content = json.encode({
            "version": 2,
            "dependency_sets": {"test": {"sets": {}}},
        }),
    )
    return module_ctx.extension_metadata(reproducible = True)

fixtures = module_extension(implementation = _fixtures_impl)
