"deb_import"

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# BUILD.bazel template
_DEB_IMPORT_BUILD_TMPL = '''
load("@rules_distroless//apt/private:deb_postfix.bzl", "deb_postfix")

deb_postfix(
    name = "data",
    srcs = glob(["data.tar*"]),
    outs = ["content.tar.gz"],
    mergedusr = {mergedusr},
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "{target_name}",
    srcs = {depends_on} + [":data"],
    visibility = ["//visibility:public"],
)
'''

def deb_import(name, depends_on = [], mergedusr = False, **kwargs):
    http_archive(
        build_file_content = _DEB_IMPORT_BUILD_TMPL.format(
            mergedusr = mergedusr,
            depends_on = depends_on,
            target_name = name,
        ),
        name = name,
        **kwargs
    )
