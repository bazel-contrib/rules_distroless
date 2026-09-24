"""A repository that exposes a single package's file list as a file.

Useful for dependents to build a file -> package filemap to resolve symlinks.
Using a file instead of raw JSON-encoded attrs saves significant space in MODULE.bazel.lock files.
This is a separate repository to avoid dependency cycle issues, which Debian package graphs allow.
"""

def _deb_filemap_impl(rctx):
    # `files` is a JSON-encoded list of the paths this package installs.
    rctx.file("filemap.json", rctx.attr.files)
    rctx.file("BUILD.bazel", 'exports_files(["filemap.json"], visibility = ["//visibility:public"])\n')

deb_filemap = repository_rule(
    implementation = _deb_filemap_impl,
    attrs = {
        "files": attr.string(
            doc = "JSON-encoded list of file paths this package installs.",
        ),
    },
)
