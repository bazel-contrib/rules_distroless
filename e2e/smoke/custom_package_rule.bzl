"""Custom rule for testing package_template in e2e smoke."""

def _custom_package_impl(ctx):
    # Verifies that custom metadata variables are passed through format_vars
    if not ctx.attr.package_name:
        fail("package_name must be non-empty")
    if not ctx.attr.package_version:
        fail("package_version must be non-empty")
    if not ctx.attr.suite:
        fail("suite must be non-empty")
    if not ctx.attr.extra_annotation:
        fail("extra_annotation must be non-empty")

    # Pass through data files as DefaultInfo
    data_files = ctx.files.data
    return [
        DefaultInfo(files = depset(data_files)),
    ]

custom_package = rule(
    implementation = _custom_package_impl,
    attrs = {
        "data": attr.label(mandatory = True, allow_files = True),
        "package_name": attr.string(mandatory = True),
        "package_version": attr.string(mandatory = True),
        "suite": attr.string(mandatory = True),
        "extra_annotation": attr.string(mandatory = True),
    },
)
