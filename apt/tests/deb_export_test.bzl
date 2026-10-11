"""Analysis tests for package-local pkg-config aliases."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//apt/private:deb_export.bzl", "deb_export")

def _pkgconfig_symlinks_test_impl(ctx):
    env = analysistest.begin(ctx)

    symlink_inputs = {}
    unpack_actions = []
    for action in analysistest.target_actions(env):
        if action.mnemonic == "Unpack":
            unpack_actions.append(action)
        elif action.mnemonic == "Symlink":
            output = action.outputs.to_list()[0]
            symlink_inputs[output.basename] = [file.basename for file in action.inputs.to_list()]

    asserts.equals(env, {
        "absolute.pc": ["original.pc"],
        "chained.pc": ["absolute.pc"],
        "foreign.pc": ["package.BUILD.tmpl"],
    }, symlink_inputs)
    asserts.equals(env, 1, len(unpack_actions))
    if unpack_actions:
        unpack = unpack_actions[0]
        asserts.equals(env, ["original.pc"], [file.basename for file in unpack.outputs.to_list()])

        # Local aliases depend on extraction. Including them here would form
        # an action cycle; only foreign aliases belong in the unpack inputs.
        asserts.equals(env, ["foreign.pc"], [
            file.basename
            for file in unpack.inputs.to_list()
            if file.basename.endswith(".pc")
        ])

    return analysistest.end(env)

pkgconfig_symlinks_test = analysistest.make(_pkgconfig_symlinks_test_impl)

def deb_export_tests():
    # deb_import normalizes /usr/share/pkgconfig/original.pc to the local
    # output name before passing an absolute alias to deb_export. A relative
    # alias can then point at that absolute alias without being re-extracted.
    # The analysis test inspects actions only; no archive is needed or built.
    deb_export(
        name = "pkgconfig_symlinks_subject",
        outs = ["pkgconfig_symlinks/usr/share/pkgconfig/original.pc"],
        symlink_outs = [
            "pkgconfig_symlinks/usr/lib/pkgconfig/foreign.pc",
            "pkgconfig_symlinks/usr/lib/pkgconfig/absolute.pc",
            "pkgconfig_symlinks/usr/lib/pkgconfig/chained.pc",
        ],
        foreign_symlinks = {"//apt/private:package.BUILD.tmpl": "[0]"},
        local_symlinks = {
            "pkgconfig_symlinks/usr/lib/pkgconfig/absolute.pc": "pkgconfig_symlinks/usr/share/pkgconfig/original.pc",
            "pkgconfig_symlinks/usr/lib/pkgconfig/chained.pc": "pkgconfig_symlinks/usr/lib/pkgconfig/absolute.pc",
        },
        tags = ["manual"],
        testonly = True,
    )
    pkgconfig_symlinks_test(
        name = "deb_export/pkgconfig_symlinks",
        target_under_test = ":pkgconfig_symlinks_subject",
    )
