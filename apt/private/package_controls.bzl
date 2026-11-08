"""Select controls for the archives a package set actually emits."""

def _package_controls_impl(ctx):
    if len(ctx.attr.data) != len(ctx.attr.controls):
        fail("data and controls must identify the same packages in the same order")

    installed = {file: None for file in ctx.files.packages}
    controls = [target[DefaultInfo].files for target in ctx.attr.root_controls]
    for data, control in zip(ctx.attr.data, ctx.attr.controls):
        if any([file in installed for file in data[DefaultInfo].files.to_list()]):
            controls.append(control[DefaultInfo].files)
    return [DefaultInfo(files = depset(transitive = controls))]

# Generated dependency sets declare the correspondence between each package's
# data and control targets. File identity also works through aliases and custom
# rules that pass through only part of the resolved dependency closure.
package_controls = rule(
    implementation = _package_controls_impl,
    attrs = {
        "packages": attr.label(mandatory = True),
        "root_controls": attr.label_list(allow_files = True),
        "data": attr.label_list(allow_files = True),
        "controls": attr.label_list(allow_files = True),
    },
)
