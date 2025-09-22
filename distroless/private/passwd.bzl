"osrelease"

load("@aspect_bazel_lib//lib:utils.bzl", "propagate_common_rule_attributes")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@tar.bzl//tar:tar.bzl", "tar")
load(":tar.bzl", "tar_lib")

# WARNING: the mode `0o644` is important
# See: https://github.com/bazelbuild/rules_docker/blob/3040e1fd74659a52d1cdaff81359f57ee0e2bb41/contrib/passwd.bzl#L149C54-L149C57
def passwd(name, entries, mode = "0644", time = "0.0", **kwargs):
    """
    Create a passwd file from array of dicts.

    https://www.ibm.com/docs/en/aix/7.3?topic=passwords-using-etcpasswd-file

    Args:
        name: name of the target
        entries: an array of dicts which will be serialized into single passwd file.

            An example;

            ```
            dict(gid = 0, uid = 0, home = "/root", shell = "/bin/bash", username = "root")
            ```
        mode: mode for the entry
        time: time for the entry
        **kwargs: other named arguments to expanded targets. see [common rule attributes](https://bazel.build/reference/be/common-definitions#common-attributes).
    """
    common_kwargs = propagate_common_rule_attributes(kwargs)
    write_file(
        name = "%s_content" % name,
        content = [
            # See: https://www.ibm.com/docs/kk/aix/7.2?topic=files-etcpasswd-file#passwd_security__a21597b8__title__1
            ":".join([
                entry["username"],
                entry.pop("password", "!"),
                str(entry["uid"]),
                str(entry["gid"]),
                ",".join(entry.pop("gecos", [])),
                entry["home"],
                entry["shell"],
            ])
            for entry in entries
        ] + [""],
        out = "%s.content" % name,
        **common_kwargs
    )

    mtree = tar_lib.create_mtree()

    # TODO: We should have a rule `rootfs` that creates the filesystem root.
    # We'll add this for now to match distroless images.
    mtree.add_dir("/etc", mode = "0755", time = "0.0")
    mtree.entry(
        "/etc/passwd",
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
