"deb_import"

load(":lockfile.bzl", "lockfile")
load(":pkgconfig.bzl", "parse_pc")
load(":util.bzl", "util")

# BUILD.bazel template
_DEB_IMPORT_BUILD_TMPL = '''
load("@rules_distroless//apt/private:deb_postfix.bzl", "deb_postfix")
load("@rules_distroless//apt/private:deb_cc_export.bzl", "deb_cc_export")
load("@rules_distroless//apt/private:apt_cursed_symlink.bzl", "apt_cursed_symlink")
load("@rules_cc//cc/private/rules_impl:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")

deb_postfix(
    name = "data",
    srcs = glob(["data.tar*"]),
    outs = ["content.tar.gz"],
    mergedusr = {mergedusr},
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "{target_name}",
    srcs = {depends_on} + [":data"],
    visibility = ["//visibility:public"],
)


deb_cc_export(
    name = "cc_export",
    src = glob(["data.tar*"])[0],
    outs = {outs},
    visibility = ["//visibility:public"]
)

{cc_import_targets}
'''

_CC_IMPORT_TMPL = """
cc_import(
    name = "{name}",
    hdrs = {hdrs},
    linkopts = {linkopts},
    includes = {includes},
    shared_library = {shared_lib},
    static_library = {static_lib},
    visibility = ["//visibility:public"],
)
"""

_CC_LIBRARY_TMPL = """
cc_library(
    name = "{name}",
    hdrs = {hdrs},
    strip_include_prefix = "usr/include",
    visibility = ["//visibility:public"],
)
"""

_CC_LIBRARY_DEP_ONLY_TMPL = """
cc_library(
    name = "{name}",
    deps = {deps},
    visibility = ["//visibility:public"]
)
"""

_APT_CURSED_SYMLINK = """
apt_cursed_symlink(
    name = "{name}_cursed",
    own_path = "{own_path}",
    candidate_path = "{candidate_path}",
    candidates = {candidates},
    out="{out}"
)
"""

def _discover_contents(rctx, depends_on, target_name):
    result = rctx.execute(["tar", "-tf", "data.tar.xz"])
    contents_raw = result.stdout.splitlines()
    so_files = []
    a_files = []
    h_files = []
    hpp_files = []
    pc_files = []
    deps = []
    excluded_files = []

    for dep in depends_on:
        (suite, name, arch, version) = lockfile.parse_package_key(dep)
        if not name.endswith("-dev"):
            # TODO:
            # This is probably not safe.
            # What if a package has a dependency (with a .so file in it)
            # but its a not -dev package?
            continue
        deps.append(
            "@%s//:%s" % (util.sanitize(dep), name.removesuffix("-dev")),
        )

    for line in contents_raw:
        # Skip everything in man pages and examples
        if line.startswith("/usr/share"):
            continue

        # Skip directories
        if line.endswith("/"):
            continue

        if (line.endswith(".so") or line.find(".so.") > 5) and line.find("lib"):
            so_files.append(line)
        elif line.endswith(".a") and line.find("lib"):
            a_files.append(line)
        elif line.endswith(".pc") and line.find("pkgconfig"):
            pc_files.append(line)
        elif line.endswith(".h") and line.startswith("./usr/include"):
            h_files.append(line)
        elif line.endswith(".hpp") and line.startswith("./usr/include"):
            hpp_files.append(line)

    build_file_content = ""

    # TODO: handle non symlink pc files similar to how we
    # handle so symlinks
    non_symlink_pc_file = None
    pc_files_all_symlink = False

    if len(pc_files):
        # TODO: use rctx.extract instead.
        r = rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + pc_files + so_files,
        )
        pc_files_all_symlink = True
        for pc in pc_files:
            if rctx.path(pc).exists:
                non_symlink_pc_file = pc
                pc_files_all_symlink = False
                break

    # Package has a pkgconfig, use that as the source of truth.
    if non_symlink_pc_file:
        pc = parse_pc(rctx.read(non_symlink_pc_file))

        (
            libname,
            includedir,
            libdir,
            linkopts,
            includes,
            defines,
        ) = _process_pcconfig(pc)

        static_lib = None
        shared_lib = None

        # Look for a static archive
        for ar in a_files:
            if ar.endswith(libname + ".a"):
                static_lib = '":%s"' % ar.removeprefix("./")
                break

        # Look for a dynamic library
        for so_lib in so_files:
            if so_lib.endswith(libname + ".so"):
                lib_path = so_lib.removeprefix("./")
                path = rctx.path(lib_path)

                # Check for dangling symlinks and search in the transitive closure
                if not path.exists:
                    candidate_path = rctx.execute(["readlink", path]).stdout.strip()
                    build_file_content += _APT_CURSED_SYMLINK.format(
                        name = target_name,
                        candidates = [
                            "@%s//:cc_export" % util.sanitize(dep)
                            for dep in depends_on
                        ],
                        own_path = so_lib,
                        candidate_path = candidate_path,
                        out = so_lib.removeprefix("./"),
                    )
                    excluded_files.append(so_lib)

                shared_lib = '":%s"' % so_lib.removeprefix("./")
                break

        build_file_content += _CC_IMPORT_TMPL.format(
            name = target_name,
            hdrs = [
                ":" + h.removeprefix("./")
                for h in h_files + hpp_files
            ],
            shared_lib = shared_lib,
            static_lib = static_lib,
            includes = [
                "external/../" + include
                for include in includes
            ],
            linkopts = linkopts,
        )

        # There were some pc files but they were all symlinks
    elif pc_files_all_symlink:
        pass

        # Package has no pkgconfig, possibly a cmake based library at the
        # standard /usr/include location and that's the only available
        # information to turn the package into a cc_library target.

    elif len(hpp_files):
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = [
                ":" + h.removeprefix("./")
                for h in h_files + hpp_files
            ],
        )

        # Package has no header files, likely a denominator package like liboost_dev
        # since it has dependencies

    elif len(depends_on):
        build_file_content += _CC_LIBRARY_DEP_ONLY_TMPL.format(
            name = target_name,
            hdrs = [],
            deps = deps,
        )

    pruned_outs = []
    if pc_files_all_symlink:
        pruned_outs = []
    else:
        pruned_outs = [
            sf
            for sf in so_files
            if sf not in excluded_files
        ] + h_files + hpp_files + a_files

    return (build_file_content, pruned_outs)

def _trim(str):
    return str.rstrip(" ").lstrip(" ")

def _process_pcconfig(pc):
    (directives, variables) = pc
    includedir = _trim(variables["includedir"])
    libdir = _trim(variables["libdir"])
    linkopts = []
    includes = []
    defines = []
    libname = None
    if "Libs" in directives:
        libs = _trim(directives["Libs"]).split(" ")
        for arg in libs:
            if arg.startswith("-l"):
                libname = "lib" + arg.removeprefix("-l")
                continue
            if arg.startswith("-L"):
                continue
            linkopts.append(arg)

    # if "Libs.private" in directives:
    #     libs = _trim(directives["Libs.private"]).split(" ")
    #     linkopts.extend([arg for arg in libs if arg.startswith("-l")])

    if "Cflags" in directives:
        cflags = _trim(directives["Cflags"]).split(" ")
        for flag in cflags:
            if flag.startswith("-I"):
                include = flag.removeprefix("-I")
                includes.append(include)

                # If the include is direct include eg $includedir (/usr/include/hiredis)
                # equals to  -I/usr/include/hiredis then we need to add /usr/include into
                # includes array to satify imports as `#include <hiredis/hiredis.h>`
                if include == includedir:
                    includes.append(include.removesuffix("/" + directives["Name"]))
                elif include.startswith(includedir):
                    includes.append(include.removesuffix("/" + directives["Name"]))
            elif flag.startswith("-D"):
                define = flag.removeprefix("-D")
                defines.append(define)

    return (libname, includedir, libdir, linkopts, includes, defines)

def _deb_import_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
    )

    # TODO: only do this if package is -dev or dependent of a -dev pkg.
    cc_import_targets, so_files = _discover_contents(
        rctx,
        rctx.attr.depends_on,
        rctx.attr.package_name.removesuffix("-dev"),
    )
    rctx.file("BUILD.bazel", _DEB_IMPORT_BUILD_TMPL.format(
        mergedusr = rctx.attr.mergedusr,
        depends_on = ["@" + util.sanitize(dep_key) for dep_key in rctx.attr.depends_on],
        target_name = rctx.attr.target_name,
        cc_import_targets = cc_import_targets,
        outs = so_files,
    ))

deb_import = repository_rule(
    implementation = _deb_import_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True, allow_empty = False),
        "sha256": attr.string(),
        "depends_on": attr.string_list(),
        "mergedusr": attr.bool(),
        "target_name": attr.string(),
        "package_name": attr.string(),
    },
)
