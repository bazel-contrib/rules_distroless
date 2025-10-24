"mtree helpers"

load("@bazel_skylib//lib:sets.bzl", "sets")
load("@tar.bzl//tar:tar.bzl", tar = "tar_lib")

DEFAULT_GID = "0"
DEFAULT_UID = "0"
DEFAULT_TIME = "0.0"
DEFAULT_MODE = "0755"
DEFAULT_ARGS = [
    # TODO: distroless uses gnu archives
    "--format",
    "gnutar",
]

def _mtree_line(dest, type, content = None, uid = DEFAULT_UID, gid = DEFAULT_GID, time = DEFAULT_TIME, mode = DEFAULT_MODE):
    # mtree expects paths to start with ./ so normalize paths that starts with
    # `/` or relative path (without / and ./)
    if not dest.startswith("."):
        if not dest.startswith("/"):
            dest = "/" + dest
        dest = "." + dest

    spec = [
        dest,
        "uid=" + uid,
        "gid=" + gid,
        "time=" + time,
        "mode=" + mode,
        "type=" + type,
    ]
    if content:
        spec.append("content=" + content)
    return " ".join(spec)

def _add_parents(path, uid = DEFAULT_UID, gid = DEFAULT_GID, time = DEFAULT_TIME, mode = DEFAULT_MODE, skip = []):
    lines = []
    segments = path.split("/")
    for i in range(0, len(segments)):
        parent = "/".join(segments[:i + 1])
        if not parent or i in skip:
            continue
        lines.append(
            _mtree_line(parent, "dir", uid = uid, gid = gid, time = time, mode = mode),
        )
    return lines

def _build_tar(ctx, mtree, output, inputs = [], compression = "gzip", mnemonic = "Tar"):
    bsdtar = ctx.toolchains[tar.toolchain_type]

    inputs = inputs[:]
    inputs.append(mtree)

    args = ctx.actions.args()
    args.add_all(DEFAULT_ARGS)
    args.add("--create")
    tar.common.add_compression_args(compression, args)
    args.add("--file", output)
    args.add(mtree, format = "@%s")

    ctx.actions.run(
        executable = bsdtar.tarinfo.binary,
        inputs = inputs,
        outputs = [output],
        tools = bsdtar.default.files,
        arguments = [args],
        mnemonic = mnemonic,
    )

def _build_mtree(ctx, content):
    mtree_out = ctx.actions.declare_file(ctx.label.name + ".spec")
    content.add("#end")
    ctx.actions.write(mtree_out, content = content)
    return mtree_out

def _array_content():
    content = []
    return struct(
        add = lambda c: content.append(c),
        add_all = lambda c, uniquify = False: content.extend(c) if uniquify else content.extend(sets.make(c).to_list()),
        to_list = lambda: content,
    )

def _create_mtree(ctx = None):
    if ctx:
        content = ctx.actions.args()
        content.set_param_file_format("multiline")
    else:
        content = _array_content()

    content.add("#mtree")
    return struct(
        entry = lambda path, type, **kwargs: content.add(_mtree_line(path, type, **kwargs)),
        add_file = lambda path, file, **kwargs: content.add(_mtree_line(path, "file", content = file.path, **kwargs)),
        add_dir = lambda path, **kwargs: content.add(_mtree_line(path, "dir", **kwargs)),
        add_parents = lambda path, **kwargs: content.add_all(_add_parents(path, **kwargs), uniquify = True),
        build = lambda **kwargs: _build_tar(ctx, _build_mtree(ctx, content), **kwargs),
        content = lambda: content.to_list() + ["#end"],
    )

tar_lib = struct(
    TOOLCHAIN_TYPE = tar.toolchain_type,
    DEFAULT_ARGS = DEFAULT_ARGS,
    create_mtree = _create_mtree,
    common = tar.common,
)
