"jks"

load(":tar.bzl", "tar_lib")

_DOC = """Create a java keystore (database) of cryptographic keys, X.509 certificate chains, and trusted certificates.

Currently only public  X.509 are supported as part of the PUBLIC API contract.
"""

def _java_keystore_impl(ctx):
    jks = ctx.actions.declare_file(ctx.attr.name + ".jks")

    args = ctx.actions.args()
    args.add(jks)
    args.add_all(ctx.files.certificates)

    ctx.actions.run(
        executable = ctx.executable._java_keystore,
        inputs = ctx.files.certificates,
        outputs = [jks],
        arguments = [args],
    )

    output = ctx.actions.declare_file(ctx.attr.name + ".tar.gz")
    mtree = tar_lib.create_mtree(ctx)

    # TODO: We should have a rule `rootfs` that creates the filesystem root.
    # We'll add this for now to match distroless images.
    mtree.add_dir("/etc", mode = ctx.attr.mode, time = "946684800")
    mtree.add_parents("/etc/ssl/certs/java", mode = ctx.attr.mode, time = ctx.attr.time, skip = [1])

    # TODO: remove??
    mtree.add_file("/etc/ssl/certs/java/cacerts", jks, mode = "0644", time = ctx.attr.time)
    mtree.build(output = output, mnemonic = "JavaKeyStore", inputs = [jks])

    return [
        DefaultInfo(files = depset([output])),
        OutputGroupInfo(
            jks = depset([jks]),
        ),
    ]

java_keystore = rule(
    doc = _DOC,
    attrs = {
        "_java_keystore": attr.label(
            executable = True,
            cfg = "exec",
            default = ":keystore_binary",
        ),
        "certificates": attr.label_list(
            allow_files = True,
            mandatory = True,
            allow_empty = False,
        ),
        "mode": attr.string(
            doc = "mode for the entries",
            default = "0755",
        ),
        "time": attr.string(
            doc = "time for the entries",
            default = "0.0",
        ),
    },
    implementation = _java_keystore_impl,
    toolchains = [
        tar_lib.TOOLCHAIN_TYPE,
    ],
)
