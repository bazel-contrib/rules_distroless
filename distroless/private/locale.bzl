"locale"

load(":tar.bzl", "tar_lib")

_DOC = """Create a locale archive from a Debian package.

An example of this would be

```starlark
# MODULE.bazel
http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "libc-bin",
    build_file_content = 'exports_files(["data.tar.xz"])',
    sha256 = "8b048ab5c7e9f5b7444655541230e689631fd9855c384e8c4a802586d9bbc65a",
    urls = ["https://snapshot.debian.org/archive/debian-security/20231106T230332Z/pool/updates/main/g/glibc/libc-bin_2.31-13+deb11u7_amd64.deb"],
)

# BUILD.bazel
load("@rules_distroless//distroless:defs.bzl", "locale")

locale(
    name = "example",
    package = "@libc-bin//:data.tar.xz"
)
```
"""

def _locale_impl(ctx):
    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]
    coreutils = ctx.toolchains["@bazel_lib//lib:coreutils_toolchain_type"]

    output = ctx.actions.declare_file(ctx.attr.name + ".tar.gz")

    args = ctx.actions.args()

    args.add(bsdtar.tarinfo.binary)
    args.add(output)
    args.add(ctx.file.package)
    args.add(ctx.attr.time)
    args.add(coreutils.coreutils_info.bin)
    args.add(ctx.executable._gawk)
    args.add("--include", "^./usr/$")
    args.add("--include", "^./usr/lib/$")
    args.add("--include", "^./usr/lib/locale/$")
    args.add("--include", "./usr/lib/locale/%s" % ctx.attr.charset)
    args.add("--include", "^./usr/share/$")
    args.add("--include", "^./usr/share/doc/$")
    args.add("--include", "^./usr/share/doc/libc-bin/$")
    args.add("--include", "^./usr/share/doc/libc-bin/copyright$")

    ctx.actions.run(
        executable = ctx.executable._locale_sh,
        inputs = [ctx.file.package],
        outputs = [output],
        tools = [
            bsdtar.default.files,
            coreutils.default.files,
            ctx.executable._gawk,
        ],
        arguments = [args],
    )
    return [
        DefaultInfo(files = depset([output])),
    ]

locale = rule(
    doc = _DOC,
    attrs = {
        "_locale_sh": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = ":locale.sh",
        ),
        "package": attr.label(
            allow_single_file = [".tar.xz", ".tar.gz", ".tar"],
            mandatory = True,
        ),
        "charset": attr.string(
            default = "C.utf8",
        ),
        "time": attr.string(
            doc = "time for the entries",
            default = "0.0",
        ),
        "_gawk": attr.label(
            allow_single_file = True,
            executable = True,
            cfg = "exec",
            default = "@gawk//:gawk",
        ),
    },
    implementation = _locale_impl,
    toolchains = [tar_lib.TOOLCHAIN_TYPE, "@bazel_lib//lib:coreutils_toolchain_type"],
)
