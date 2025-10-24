"os release"

load("@bazel_lib//lib:utils.bzl", "propagate_common_rule_attributes")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@tar.bzl//tar:tar.bzl", "tar")
load(":tar.bzl", "tar_lib")

def os_release(
        name,
        content,
        path = "/usr/lib/os-release",
        mode = "0555",
        time = "0",
        **kwargs):
    """
    Create an Operating System Identification file from a key, value dictionary.

    https://www.freedesktop.org/software/systemd/man/latest/os-release.html

    Args:
        name: name of the target
        content: a key, value dictionary that will be serialized into `=` seperated lines.

            See https://www.freedesktop.org/software/systemd/man/latest/os-release.html#Options for well known keys.
        path: where to put the file in the result archive. default: `/usr/lib/os-release`
        mode: mode for the entry
        time: time for the entry
        **kwargs: other named arguments to expanded targets. see [common rule attributes](https://bazel.build/reference/be/common-definitions#common-attributes).
    """
    common_kwargs = propagate_common_rule_attributes(kwargs)
    write_file(
        name = "%s_content" % name,
        content = [
            "{}={}".format(key, value)
            for (key, value) in content.items()
        ] + [""],
        out = "%s.content" % name,
        **common_kwargs
    )

    mtree = tar_lib.create_mtree()

    i = path.rfind("/")
    mtree.add_parents(path[0:i], time = time)
    mtree.entry(
        path.lstrip("/").lstrip("./"),
        "file",
        mode = mode,
        time = time,
        content = "$(BINDIR)/$(rootpath :%s_content)" % name,
    )

    tar(
        name = name,
        srcs = [":%s_content" % name],
        mtree = mtree.content(),
        args = tar_lib.DEFAULT_ARGS,
        compress = "gzip",
        **common_kwargs
    )
