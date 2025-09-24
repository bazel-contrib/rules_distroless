"normalization rules"

# buildifier: disable=function-docstring-args
def deb_cc_export(name, src, outs, **kwargs):
    """Private. DO NOT USE."""
    if len(outs) == 0:
        native.filegroup(name = name, srcs = [], **kwargs)
        return
    toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"]

    cmd = """
$(BSDTAR_BIN) -xf "$<" -C $(RULEDIR) {}  \
""".format(
        " ".join(outs),
    )
    native.genrule(
        name = name,
        srcs = [src],
        outs = [out.removeprefix("./") for out in outs],
        cmd = cmd,
        toolchains = toolchains,
        output_to_bindir = True,
        **kwargs
    )
