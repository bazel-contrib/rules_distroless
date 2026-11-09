"""Check imported Boost headers without relying on host installations."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _headers_only_impl(ctx):
    # This fixture uses only Boost headers, not any Debian runtime libraries.
    return [CcInfo(compilation_context = ctx.attr.dep[CcInfo].compilation_context)]

headers_only = rule(
    implementation = _headers_only_impl,
    attrs = {"dep": attr.label(mandatory = True, providers = [CcInfo])},
)

def _declared_headers_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    headers = [file.short_path for file in target[CcInfo].compilation_context.headers.to_list()]
    for path in [
        "boost/xpressive/detail/utility/chset/basic_chset.ipp",
        "boost/spirit/home/classic/utility/impl/chset/basic_chset.ipp",
        "boost/version.hpp",
    ]:
        asserts.true(
            env,
            any([header.endswith("/usr/include/" + path) for header in headers]),
            "Missing declared Boost header: " + path,
        )
    return analysistest.end(env)

declared_headers_test = analysistest.make(_declared_headers_test_impl)
