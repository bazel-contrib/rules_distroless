"home"

load("@tar.bzl//tar:tar.bzl", "tar")
load(":tar.bzl", "tar_lib")
load(":util.bzl", "util")

def home(name, dirs, **kwargs):
    """
    Create home directories with specific uid and gids.

    Args:
        name: name of the target
        dirs: array of home directory dicts.
        **kwargs: other named arguments to that is passed to tar. see [common rule attributes](https://bazel.build/reference/be/common-definitions#common-attributes).
    """
    mtree = tar_lib.create_mtree()

    for home in dirs:
        mtree.add_dir(
            util.get_attr(home, "home"),
            uid = str(util.get_attr(home, "uid")),
            gid = str(util.get_attr(home, "gid")),
            time = str(util.get_attr(home, "time", 0)),
            # the default matches https://github.com/bazelbuild/rules_docker/blob/3040e1fd74659a52d1cdaff81359f57ee0e2bb41/contrib/passwd.bzl#L81C24-L81C27
            mode = str(util.get_attr(home, "mode", "700")),
        )

    tar(
        name = name,
        mtree = mtree.content(),
        args = tar_lib.DEFAULT_ARGS,
        compress = "gzip",
        **kwargs
    )
