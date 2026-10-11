"""Check public metadata file sets and compare bytes to published .debs."""

load("@bazel_skylib//lib:shell.bzl", "shell")

TAR_TOOLCHAIN_TYPE = "@tar.bzl//tar/toolchain:type"

def _target_platform_impl(_settings, attr):
    return {"//command_line_option:platforms": str(attr.platform)}

_target_platform = transition(
    implementation = _target_platform_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _runfile(file):
    return '"${TEST_SRCDIR}/${TEST_WORKSPACE}/"' + shell.quote(file.short_path)

def _pkgconfig_test_impl(ctx):
    expected = {}
    bsdtar = ctx.toolchains[TAR_TOOLCHAIN_TYPE]
    script = ["#!/usr/bin/env bash", "set -euo pipefail"]
    files = []
    for i, (archive_target, members_json) in enumerate(ctx.attr.originals.items()):
        archive = archive_target[DefaultInfo].files.to_list()[0]
        files.append(archive)
        script.append('{} -xOf {} data.tar.xz > "$TEST_TMPDIR/{}.tar.xz"'.format(
            _runfile(bsdtar.tarinfo.binary),
            _runfile(archive),
            i,
        ))
        for path, member in json.decode(members_json).items():
            expected[path] = (i, member)

    for target in ctx.attr.targets:
        actual = {}
        for file in target[DefaultInfo].files.to_list():
            # All exports retain the path within their original package.
            path = file.short_path.split("/", 2)[2]
            if path in actual:
                fail("{} exports duplicate {}".format(target.label, path))
            if file.owner.repo_name.endswith("_mergedusr") != ctx.attr.mergedusr:
                fail("{} uses the wrong mergedusr repository: {}".format(target.label, file.owner))
            actual[path] = file
        if sorted(actual) != sorted(expected):
            fail("{}: expected {}, got {}".format(target.label, sorted(expected), sorted(actual)))
        for path, file in actual.items():
            archive_index, member = expected[path]
            files.append(file)
            script.extend([
                '{} -xOf "$TEST_TMPDIR/{}.tar.xz" {} > "$TEST_TMPDIR/expected.pc"'.format(
                    _runfile(bsdtar.tarinfo.binary),
                    archive_index,
                    shell.quote("./" + member),
                ),
                'cmp "$TEST_TMPDIR/expected.pc" {}'.format(_runfile(file)),
            ])
    executable = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(executable, "\n".join(script) + "\n", is_executable = True)
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(files = files, transitive_files = bsdtar.default.files),
    )]

pkgconfig_test = rule(
    implementation = _pkgconfig_test_impl,
    test = True,
    attrs = {
        "targets": attr.label_list(mandatory = True, cfg = _target_platform),
        "originals": attr.label_keyed_string_dict(allow_files = True),
        "platform": attr.label(mandatory = True),
        "mergedusr": attr.bool(),
        "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    },
    toolchains = [TAR_TOOLCHAIN_TYPE],
)

def originals(architecture, packages = ["liblua5.4-dev", "zlib1g-dev", "xtrans-dev"]):
    """Map exported names to original tar members, including the Lua symlinks."""
    libdir = "usr/lib/{}/pkgconfig/".format({"amd64": "x86_64-linux-gnu", "arm64": "aarch64-linux-gnu"}[architecture])
    result = {}
    if "liblua5.4-dev" in packages:
        result["@pkgconfig_original_liblua5.4-dev_{}//file".format(architecture)] = json.encode({
            libdir + name + suffix + ".pc": libdir + "lua5.4" + suffix + ".pc"
            for name in ["lua5.4", "lua-5.4", "lua54"]
            for suffix in ["", "-c++"]
        })
    if "zlib1g-dev" in packages:
        result["@pkgconfig_original_zlib1g-dev_{}//file".format(architecture)] = json.encode({
            libdir + "zlib.pc": libdir + "zlib.pc",
        })
    if "xtrans-dev" in packages:
        result["@pkgconfig_original_xtrans-dev_all//file"] = json.encode({
            "usr/share/pkgconfig/xtrans.pc": "usr/share/pkgconfig/xtrans.pc",
        })
    return result
