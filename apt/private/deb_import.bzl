"deb_import"

load(":lockfile.bzl", "lockfile")
load(":pkgconfig.bzl", "pkgconfig")
load(":util.bzl", "util")

# BUILD.bazel template
_DEB_IMPORT_BUILD_TMPL = '''
load("@rules_distroless//apt/private:deb_postfix.bzl", "deb_postfix")
load("@rules_distroless//apt/private:deb_cc_export.bzl", "deb_cc_export")
load("@rules_distroless//apt/private:apt_cursed_symlink.bzl", "apt_cursed_symlink")
load("@rules_cc//cc/private/rules_impl:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

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
    srcs = glob(["data.tar*"]),
    foreign_symlinks = {foreign_symlinks},
    symlink_outs = {symlink_outs},
    outs = {outs},
    visibility = ["//visibility:public"]
)

directory(
    name = "directory",
    srcs = {symlink_outs} + {outs},
    visibility = ["//visibility:public"]
)

{cc_import_targets}
'''

_CC_IMPORT_TMPL = """
cc_import(
    name = "{name}_imp_",
    hdrs = {hdrs},
    includes = {includes},
    shared_library = {shared_lib},
    static_library = {static_lib},
)

cc_library(
    name = "{name}",
    deps = [":{name}_imp_"],
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    linkopts = {linkopts},
)
"""

_CC_IMPORT_SINGLE_TMPL = """
cc_import(
    name = "{name}_import",
    hdrs = {hdrs},
    includes = {includes},
    shared_library = {shared_lib},
    static_library = {static_lib},
)

cc_library(
    name = "{name}_wodeps",
    deps = [":{name}_import"],
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    linkopts = {linkopts},
    visibility = ["//visibility:public"],
)


cc_library(
    name = "{name}",
    deps = [":{name}_wodeps"] + {deps},
    visibility = ["//visibility:public"],
)
"""

_CC_IMPORT_DENOMITATOR = """
cc_library(
    name = "{name}_wodeps",
    deps = {targets},
    visibility = ["//visibility:public"],
)

cc_library(
    name = "{name}",
    deps = [":{name}_wodeps"] + {deps},
    visibility = ["//visibility:public"],
)
"""

_CC_LIBRARY_LIBC_TMPL = """
alias(
    name = "{name}_wodeps",
    actual = ":{name}",
    visibility = ["//visibility:public"]
)

cc_library(
    name = "{name}",
    hdrs = {hdrs},
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    includes = {includes},
    visibility = ["//visibility:public"],
)
"""

_CC_LIBRARY_TMPL = """
cc_library(
    name = "{name}_wodeps",
    hdrs = {hdrs},
    srcs = {srcs},
    linkopts = {linkopts},
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    strip_include_prefix = "{strip_include_prefix}",
    visibility = ["//visibility:public"],
)

cc_library(
    name = "{name}",
    deps = [":{name}_wodeps"] + {deps},
    visibility = ["//visibility:public"],
)
"""

def resolve_symlink(target_path, relative_symlink):
    # Split paths into components
    target_parts = target_path.split("/")
    symlink_parts = relative_symlink.split("/")

    # Remove the file name from target path to get the directory
    target_dir_parts = target_parts[:-1]

    # Process the relative symlink
    result_parts = target_dir_parts[:]
    for part in symlink_parts:
        if part == "..":
            # Move up one directory by removing the last component
            if result_parts:
                result_parts.pop()
        elif part == "." or part == "":
            # Ignore current directory or empty components
            continue
        else:
            # Append the component to the path
            result_parts.append(part)

    # Join the parts back into a path
    resolved_path = "/".join(result_parts)
    return resolved_path

def _discover_contents(rctx, depends_on, depends_file_map, target_name):
    result = rctx.execute(["tar", "--exclude='./usr/share/**'", "--exclude='./**/'", "-tvf", "data.tar.xz"])
    contents_raw = result.stdout.splitlines()

    so_files = []
    a_files = []
    h_files = []
    hpp_files = []
    hpp_files_woext = []
    pc_files = []
    o_files = []
    symlinks = {}

    for line in contents_raw:
        # Skip directories
        if line.endswith("/"):
            continue

        line = line[line.find(" ./") + 3:]

        # Skip everything in man pages and examples
        if line.startswith("usr/share"):
            continue

        is_symlink_idx = line.find(" -> ")
        resolved_symlink = None
        if is_symlink_idx != -1:
            symlink_target = line[is_symlink_idx + 4:]
            line = line[:is_symlink_idx]
            if line.endswith(".pc"):
                continue

            # An absolute symlink
            if symlink_target.startswith("/"):
                resolved_symlink = symlink_target.removeprefix("/")
            else:
                resolved_symlink = resolve_symlink(line, symlink_target).removeprefix("./")

        if (line.endswith(".so") or line.find(".so.") != -1) and line.find("lib") != -1:
            if line.find("libthread_db") != -1:
                continue
            so_files.append(line)
        elif line.endswith(".a") and line.find("lib"):
            a_files.append(line)
        elif line.endswith(".pc") and line.find("pkgconfig"):
            pc_files.append(line)
        elif line.endswith(".h"):
            h_files.append(line)
        elif line.endswith(".hpp"):
            hpp_files.append(line)
        elif line.find("include/c++") != -1:
            hpp_files_woext.append(line)
        elif line.endswith(".o"):
            o_files.append(line)
        else:
            continue

        if resolved_symlink:
            symlinks[line] = resolved_symlink

    # Resolve symlinks:
    unresolved_symlinks = {} | symlinks

    # TODO: this is highly inefficient, change the filemapping to be
    # file -> package instead of package -> files
    for dep in depends_on:
        (suite, name, arch, version) = lockfile.parse_package_key(dep)
        filemap = depends_file_map.get(name, []) or []
        for file in filemap:
            if len(unresolved_symlinks) == 0:
                break
            for (symlink, symlink_target) in unresolved_symlinks.items():
                if file == symlink_target:
                    unresolved_symlinks.pop(symlink)
                    symlinks[symlink] = "@%s//:%s" % (util.sanitize(dep), file)

    for file in so_files + h_files + hpp_files + a_files + hpp_files_woext:
        for (symlink, symlink_target) in unresolved_symlinks.items():
            if file == symlink_target:
                symlinks.pop(symlink)
                unresolved_symlinks.pop(symlink)
                if len(unresolved_symlinks) == 0:
                    break

    if len(unresolved_symlinks):
        util.warning(
            rctx,
            "some symlinks could not be solved for {}. \nresolved: {}\nunresolved:{}".format(
                target_name,
                json.encode_indent(symlinks),
                json.encode_indent(unresolved_symlinks),
            ),
        )

    outs = []

    for out in so_files + h_files + hpp_files + a_files + hpp_files_woext + o_files:
        if out not in symlinks:
            outs.append(out)

    deps = []
    for dep in depends_on:
        (suite, name, arch, version) = lockfile.parse_package_key(dep)
        deps.append(
            "@%s//:%s_wodeps" % (util.sanitize(dep), name.removesuffix("-dev")),
        )

    r_pc_files = []
    if len(pc_files):
        # TODO: use rctx.extract instead.
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + pc for pc in pc_files],
        )
        for pc in pc_files:
            if rctx.path(pc).exists:
                r_pc_files.append(pc)

    build_file_content = ""

    rpaths = {}
    for so in so_files + a_files:
        rpath = so[:so.rfind("/")]
        rpaths[rpath] = None

    # Package has a pkgconfig, use that as the source of truth.
    if len(r_pc_files) == 1:
        pkgc = pkgconfig(rctx, r_pc_files[0])

        static_lib = None
        shared_lib = None

        # Look for a static archive
        for ar in a_files:
            if ar.endswith(pkgc.libname + ".a"):
                static_lib = '":%s"' % ar
                break

        # Look for a dynamic library
        for so_lib in so_files:
            if so_lib.endswith(pkgc.libname + ".so"):
                shared_lib = '":%s"' % so_lib
                break

        build_file_content += _CC_IMPORT_SINGLE_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + o_files + a_files,
            shared_lib = shared_lib,
            static_lib = static_lib,
            includes = [
                "external/.." + include
                for include in pkgc.includes
            ],
            linkopts = pkgc.linkopts + [
                "-Wl,-rpath=/" + rp
                for rp in rpaths
            ] + [
                "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, lp)
                for lp in pkgc.link_paths
            ],
            deps = deps,
        )
    elif len(r_pc_files) > 1:
        targets = []
        for pc_file in r_pc_files:
            pkgc = pkgconfig(rctx, pc_file)

            if not pkgc.libname or "_" + pkgc.libname in targets:
                continue

            subtarget = "_" + pkgc.libname

            targets.append(subtarget)

            static_lib = None
            shared_lib = None

            # Look for a static archive
            for ar in a_files:
                if ar.endswith(pkgc.libname + ".a"):
                    static_lib = '":%s"' % ar
                    break

            # Look for a dynamic library
            for so_lib in so_files:
                if so_lib.endswith(pkgc.libname + ".so"):
                    shared_lib = '":%s"' % so_lib
                    break

            build_file_content += _CC_IMPORT_TMPL.format(
                name = subtarget,
                hdrs = h_files + hpp_files,
                additional_compiler_inputs = hpp_files_woext,
                additional_linker_inputs = so_files + o_files + a_files,
                shared_lib = shared_lib,
                static_lib = static_lib,
                includes = [
                    "external/.." + include
                    for include in pkgc.includes
                ],
                linkopts = pkgc.linkopts + [
                    "-Wl,-rpath=/" + rp
                    for rp in rpaths
                ] + [
                    "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, lp)
                    for lp in pkgc.link_paths
                ],
                deps = deps,
            )

        build_file_content += _CC_IMPORT_DENOMITATOR.format(
            name = target_name,
            targets = targets,
            deps = deps,
        )

    elif (len(hpp_files) or len(h_files)) and ((target_name.find("libc") != -1 or target_name.find("libstdc") != -1 or target_name.find("libgcc") != -1)):
        build_file_content += _CC_LIBRARY_LIBC_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + a_files + o_files,
            includes = [],
        )
    else:
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            deps = deps,
            srcs = [],
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + a_files + o_files,
            linkopts = [
                "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, rpath)
                for rpath in rpaths
            ] + [
                "-Wl,-rpath=/" + rp
                for rp in rpaths
            ] + [
                "-Wl,-rpath-link=$(BINDIR)/external/{}/{}".format(rctx.attr.name, rpath)
                for rp in rpaths
            ],
            strip_include_prefix = "usr/include",
        )

    return (build_file_content, outs, symlinks)

def _deb_import_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
    )

    # TODO: only do this if package is -dev or dependent of a -dev pkg.
    cc_import_targets, outs, symlinks = _discover_contents(
        rctx,
        rctx.attr.depends_on,
        json.decode(rctx.attr.depends_file_map),
        rctx.attr.package_name.removesuffix("-dev"),
    )

    rctx.file("BUILD.bazel", _DEB_IMPORT_BUILD_TMPL.format(
        mergedusr = rctx.attr.mergedusr,
        depends_on = ["@" + util.sanitize(dep_key) + "//:data" for dep_key in rctx.attr.depends_on],
        target_name = rctx.attr.target_name,
        cc_import_targets = cc_import_targets,
        outs = outs,
        foreign_symlinks = {
            str(i): symlink
            for (i, symlink) in enumerate(symlinks.values())
        },
        symlink_outs = symlinks.keys(),
    ))

deb_import = repository_rule(
    implementation = _deb_import_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True, allow_empty = False),
        "sha256": attr.string(),
        "depends_on": attr.string_list(),
        "depends_file_map": attr.string(),
        "mergedusr": attr.bool(),
        "target_name": attr.string(),
        "package_name": attr.string(),
    },
)
