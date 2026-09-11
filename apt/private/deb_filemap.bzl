"""A repository that exposes a single package's file list as a file.

Useful for dependents to build a file -> package filemap to resolve symlinks.
Using a file instead of raw JSON-encoded attrs saves significant space in MODULE.bazel.lock files.
This is a separate repository to avoid dependency cycle issues, which Debian package graphs allow.
"""

load(":deb_archive.bzl", "data_archive", "host_bsdtar")

def _deb_filemap_impl(rctx):
    # Contents indexes describe entire distributions and may be absent from
    # third-party repositories. Inspect the exact pinned package on demand.
    rctx.download_and_extract(url = rctx.attr.urls, sha256 = rctx.attr.sha256, output = "_archive")
    result = rctx.execute([host_bsdtar(rctx), "-tf", data_archive(rctx, "_archive")])
    if result.return_code:
        fail("failed to list package files: %s" % result.stderr)
    rctx.delete("_archive")
    files = [path.removeprefix("./") for path in result.stdout.splitlines() if not path.endswith("/")]
    rctx.file("filemap.json", json.encode({"package_key": rctx.attr.package_key, "files": files}))
    rctx.file("BUILD.bazel", 'exports_files(["filemap.json"], visibility = ["//visibility:public"])\n')

deb_filemap = repository_rule(
    implementation = _deb_filemap_impl,
    attrs = {
        "package_key": attr.string(mandatory = True),
        "urls": attr.string_list(mandatory = True, allow_empty = False),
        "sha256": attr.string(mandatory = True),
    },
)
