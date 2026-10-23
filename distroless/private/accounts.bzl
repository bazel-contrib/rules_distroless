"""Preserve a base image's accounts while adding service users and groups."""

load("@bazel_lib//lib:utils.bzl", "propagate_common_rule_attributes")
load("@tar.bzl//tar:tar.bzl", "tar")
load(":group.bzl", "group")
load(":passwd.bzl", "passwd")
load(":tar.bzl", "tar_lib")

def _merge_impl(ctx):
    if not ctx.file.base.is_directory:
        fail("accounts requires a single OCI layout directory")
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]
    args = ctx.actions.args()
    args.add("--base", ctx.file.base.path)
    args.add("--users", ctx.file.users)
    args.add("--groups", ctx.file.groups)
    args.add("--architecture", ctx.attr.architecture)
    args.add("--bsdtar", bsdtar.tarinfo.binary)
    args.add("--passwd-out", ctx.outputs.passwd)
    args.add("--group-out", ctx.outputs.group)
    args.add("--receipt", ctx.outputs.receipt)
    outputs = [ctx.outputs.passwd, ctx.outputs.group, ctx.outputs.receipt]
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = [ctx.file.base, ctx.file.users, ctx.file.groups],
        tools = bsdtar.default.files,
        outputs = outputs,
        mnemonic = "MergeImageAccounts",
    )
    return [DefaultInfo(files = depset(outputs))]

_merge = rule(
    implementation = _merge_impl,
    attrs = {
        "base": attr.label(allow_single_file = True, mandatory = True),
        "users": attr.label(allow_single_file = True, mandatory = True),
        "groups": attr.label(allow_single_file = True, mandatory = True),
        "architecture": attr.string(mandatory = True),
        "passwd": attr.output(mandatory = True),
        "group": attr.output(mandatory = True),
        "receipt": attr.output(mandatory = True),
        "_tool": attr.label(default = Label(":accounts_tool"), executable = True, cfg = "exec"),
    },
    toolchains = [tar_lib.TOOLCHAIN_TYPE],
)

def accounts(name, base, architecture, users = [], groups = [], **kwargs):
    """Add service accounts to an OCI base without replacing inherited entries.

    Use the resulting TAR in `oci_image.tars` with the same `base`. Only
    `/etc/passwd` and `/etc/group` are produced; home directories, password
    databases and package configuration are separate steps. The rules_python
    execution toolchain and BSD tar toolchain read the base and its compressed
    layers without running programs from the image.

    Args:
        name: Target name for the merged account TAR.
        base: Single-platform OCI layout directory containing both account files.
        architecture: Expected Linux OCI architecture, such as `amd64` or `arm64`.
        users: Additional entries in the same dictionary format as `passwd`.
        groups: Additional entries in the same dictionary format as `group`.
        **kwargs: Common Bazel attributes forwarded to the generated rules.

    Existing account bytes are preserved. Identical existing entries are retained;
    conflicting names/IDs are errors. User primary groups and group members are
    checked against the combined records, so users and groups are declared in one
    operation. `<name>.receipt` records the base digest and output hashes.
    """
    common_kwargs = propagate_common_rule_attributes(kwargs)

    # passwd consumes optional dictionary keys; avoid mutating the caller's data.
    passwd(name = name + "_users", entries = [dict(entry) for entry in users], **common_kwargs)
    group(name = name + "_groups", entries = groups, **common_kwargs)
    state = name + "_state"
    _merge(
        name = state,
        base = base,
        architecture = architecture,
        users = ":" + name + "_users",
        groups = ":" + name + "_groups",
        passwd = state + ".passwd",
        group = state + ".group",
        receipt = state + ".json",
        **common_kwargs
    )
    tar(
        name = name,
        srcs = [":" + state + ".passwd", ":" + state + ".group"],
        mtree = [
            "./etc uid=0 gid=0 mode=0755 time=0 type=dir",
            "./etc/passwd uid=0 gid=0 mode=0644 time=0 type=file content=$(location :" + state + ".passwd)",
            "./etc/group uid=0 gid=0 mode=0644 time=0 type=file content=$(location :" + state + ".group)",
        ],
        **common_kwargs
    )
    native.filegroup(name = name + ".receipt", srcs = [":" + state + ".json"], **common_kwargs)
