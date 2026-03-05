"cacerts"

load(":tar.bzl", "tar_lib")

_DOC = """Create a ca-certificates.crt bundle from Common CA certificates.

When provided with the `ca-certificates` Debian package it will create a bundle
of all common CA certificates at `/usr/share/ca-certificates` and bundle them into
a `ca-certificates.crt` file at `/etc/ssl/certs/ca-certificates.crt`

An example of this would be

```starlark
# MODULE.bazel
http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "ca-certificates",
    type = ".deb",
    sha256 = "b2d488ad4d8d8adb3ba319fc9cb2cf9909fc42cb82ad239a26c570a2e749c389",
    urls = ["https://snapshot.debian.org/archive/debian/20231106T210201Z/pool/main/c/ca-certificates/ca-certificates_20210119_all.deb"],
    build_file_content = "exports_files(["data.tar.xz"])"
)

# BUILD.bazel
load("@rules_distroless//distroless:defs.bzl", "cacerts")

cacerts(
    name = "example",
    package = "@ca-certificates//:data.tar.xz",
)
```

To use the generated certificate bundle for SSL, **you must set SSL_CERT_FILE in the
environment**. You can set it on the oci image like so:
```starlark
oci_image(
    name = "my-image",
    env = {
        "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
    }
)
```
"""

def _cacerts_impl(ctx):
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]
    coreutils = ctx.toolchains["@bazel_lib//lib:coreutils_toolchain_type"]

    cacerts = ctx.actions.declare_file(ctx.attr.name + ".crt")
    copyright = ctx.actions.declare_file(ctx.attr.name + ".copyright")
    ctx.actions.run(
        executable = ctx.executable._cacerts_sh,
        inputs = [ctx.file.package],
        outputs = [cacerts, copyright],
        tools = [
            bsdtar.default.files,
            coreutils.default.files,
        ],
        arguments = [
            bsdtar.tarinfo.binary.path,
            ctx.file.package.path,
            cacerts.path,
            copyright.path,
            coreutils.coreutils_info.bin.path,
        ],
    )

    output = ctx.actions.declare_file(ctx.attr.name + ".tar.gz")
    mtree = tar_lib.create_mtree(ctx)

    # TODO: We should have a rule `rootfs` that creates the filesystem root.
    # We'll add this for now to match distroless images.
    mtree.add_dir("/etc", mode = "0755", time = ctx.attr.time)
    mtree.add_parents("/etc/ssl/certs", mode = "0755", time = ctx.attr.time, skip = [1])
    mtree.add_file("/etc/ssl/certs/ca-certificates.crt", cacerts, time = ctx.attr.time, mode = ctx.attr.mode)
    mtree.add_parents("/usr/share/doc/ca-certificates", time = ctx.attr.time)
    mtree.add_file("/usr/share/doc/ca-certificates/copyright", copyright, time = ctx.attr.time, mode = ctx.attr.mode)
    mtree.build(output = output, mnemonic = "CaCertsTarGz", inputs = [cacerts, copyright])

    return [
        DefaultInfo(files = depset([output])),
    ]

cacerts = rule(
    doc = _DOC,
    attrs = {
        "_cacerts_sh": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = ":cacerts.sh",
        ),
        "package": attr.label(
            allow_single_file = [".tar.zst", ".tar.xz", ".tar.gz", ".tar"],
            mandatory = True,
        ),
        "mode": attr.string(
            doc = "mode for the entries",
            default = "0555",
        ),
        "time": attr.string(
            doc = "time for the entries",
            default = "0.0",
        ),
    },
    implementation = _cacerts_impl,
    toolchains = [tar_lib.TOOLCHAIN_TYPE, "@bazel_lib//lib:coreutils_toolchain_type"],
)
