"deb_import"

load(":lockfile.bzl", "lockfile")
load(":pkgconfig.bzl", "parse_pc", "process_pcconfig")
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
    symlinks = {symlinks},
    symlink_outs = {symlink_outs},
    self_symlink_outs = {self_symlink_outs},
    self_symlink_output_indices = {self_symlink_output_indices},
    outs = {outs},
    visibility = ["//visibility:public"]
)

directory(
    name = "directory",
    srcs = {symlink_outs} + {outs} + {self_symlink_outs},
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
    additional_linker_inputs = {additional_linker_inputs},
    strip_include_prefix = "{strip_include_prefix}",
    visibility = ["//visibility:public"],
)
"""

_CC_LIBRARY_LIBC_TMPL = """
cc_library(
    name = "{name}",
    hdrs = {hdrs},
    srcs = {srcs},
    includes = {includes},
    additional_compiler_inputs = {additional_compiler_inputs},
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

def _discover_contents(rctx, depends_on, direct_depends_on, direct_depends_file_map, target_name):
    result = rctx.execute(["tar", "--exclude='./usr/share/**'", "--exclude='./**/'", "-tvf", "data.tar.xz"])
    contents_raw = result.stdout.splitlines()
    so_files = []
    a_files = []
    h_files = []
    hpp_files = []
    hpp_files_woext = []
    pc_files = []
    symlinks = {}
    deps = []
    excluded_files = []

    for line in contents_raw:
        # Skip directories
        if line.endswith("/"):
            continue

        line = line[line.find(" ./") + 3:]

        # Skip everything in man pages and examples
        if line.startswith("usr/share"):
            continue

        is_symlink_idx = line.find(" -> ")
        if is_symlink_idx != -1:
            symlink_target = line[is_symlink_idx + 4:]
            line = line[:is_symlink_idx]
            if line.endswith(".pc"):
                continue
            symlinks[line] = resolve_symlink(line, symlink_target).removeprefix("./")

        if (line.endswith(".so") or line.find(".so.") != -1) and line.find("lib") != -1:
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

    # Resolve symlinks:
    resolved_symlinks = list([None] * len(symlinks))
    symlink_targets = {
        v: k
        for (k, v) in symlinks.items()
    }
    osymlinks = symlinks
    symlinks = {
        k: None
        for k in symlinks.keys()
    }
    solved_symlinks = 0
    for dep in direct_depends_on or depends_on:
        (suite, name, arch, version) = lockfile.parse_package_key(dep)
        filemap = direct_depends_file_map.get(name, []) or []
        for file in filemap:
            if file in symlink_targets:
                symlink_path = symlink_targets[file]
                symlinks[symlink_path] = "@%s//:%s" % (util.sanitize(dep), file)
                solved_symlinks += 1
                if solved_symlinks == len(symlink_targets):
                    break

    outs = []

    for out in so_files + h_files + hpp_files + a_files + hpp_files_woext:
        if out not in symlinks:
            outs.append(out)

    self_symlinks = {}
    for (i, file) in enumerate(outs):
        if file in symlink_targets:
            symlink_path = symlink_targets[file]
            self_symlinks[symlink_path] = i
            solved_symlinks += 1
            if solved_symlinks == len(symlink_targets):
                break

    if solved_symlinks < len(symlink_targets):
        util.warning(rctx, "some symlinks could not be solved for {}. \n{}".format(target_name, osymlinks))

    build_file_content = ""

    # TODO: handle non symlink pc files similar to how we
    # handle so symlinks
    non_symlink_pc_file = None

    if len(pc_files):
        # TODO: use rctx.extract instead.
        r = rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + pc for pc in pc_files],
        )
        for pc in pc_files:
            if rctx.path(pc).exists:
                non_symlink_pc_file = pc
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
        ) = process_pcconfig(pc)

        static_lib = None
        shared_lib = None

        # Look for a static archive
        for ar in a_files:
            if ar.endswith(libname + ".a"):
                static_lib = '":%s"' % ar
                break

        # Look for a dynamic library
        for so_lib in so_files:
            if so_lib.endswith(libname + ".so"):
                lib_path = so_lib
                path = rctx.path(lib_path)
                shared_lib = '":%s"' % so_lib
                break

        build_file_content += _CC_IMPORT_TMPL.format(
            name = target_name,
            hdrs = [
                ":" + h
                for h in h_files + hpp_files
            ],
            shared_lib = shared_lib,
            static_lib = static_lib,
            includes = [
                "external/.." + include
                for include in includes
            ],
            linkopts = linkopts,
        )

    elif (len(hpp_files) or len(h_files)) and ((target_name.find("libc") != -1 or target_name.find("libstdc") != -1 or target_name.find("libgcc") != -1)):
        build_file_content += _CC_LIBRARY_LIBC_TMPL.format(
            name = target_name,
            hdrs = [
                ":" + h
                for h in h_files + hpp_files
            ],
            srcs = [
                # ":" + so
                # for so in so_files
            ],
            additional_compiler_inputs = hpp_files_woext,
            includes = [],
        )

    elif len(hpp_files) or len(h_files):
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = [
                ":" + h
                for h in h_files + hpp_files
            ],
            additional_linker_inputs = [],
            strip_include_prefix = "usr/include",
        )

        # Package has no header files, likely a denominator package like liboost-dev
        # since it has dependencies

    elif len(depends_on):
        deps = []
        for dep in depends_on:
            (suite, name, arch, version) = lockfile.parse_package_key(dep)
            deps.append(
                "@%s//:%s" % (util.sanitize(dep), name.removesuffix("-dev")),
            )

        build_file_content += _CC_LIBRARY_DEP_ONLY_TMPL.format(
            name = target_name,
            deps = deps,
        )
    elif len(so_files):
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            additional_linker_inputs = [
                ":" + h
                for h in so_files
            ],
            hdrs = [],
            strip_include_prefix = "usr/include",
        )
    else:
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            additional_linker_inputs = [],
            hdrs = [],
            strip_include_prefix = "usr/include",
        )

    return (build_file_content, outs, symlinks, self_symlinks)

def _deb_import_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
    )

    # TODO: only do this if package is -dev or dependent of a -dev pkg.
    cc_import_targets, outs, symlinks, self_symlinks = _discover_contents(
        rctx,
        rctx.attr.depends_on,
        rctx.attr.direct_depends_on,
        json.decode(rctx.attr.direct_depends_file_map),
        rctx.attr.package_name.removesuffix("-dev"),
    )

    rctx.file("BUILD.bazel", _DEB_IMPORT_BUILD_TMPL.format(
        mergedusr = rctx.attr.mergedusr,
        depends_on = ["@" + util.sanitize(dep_key) for dep_key in rctx.attr.depends_on],
        target_name = rctx.attr.target_name,
        cc_import_targets = cc_import_targets,
        outs = outs,
        symlinks = [value for value in symlinks.values() if value],
        symlink_outs = [k for (k, v) in symlinks.items() if v],
        self_symlink_outs = self_symlinks.keys(),
        self_symlink_output_indices = self_symlinks.values(),
    ))

deb_import = repository_rule(
    implementation = _deb_import_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True, allow_empty = False),
        "sha256": attr.string(),
        "depends_on": attr.string_list(),
        "direct_depends_on": attr.string_list(),
        "direct_depends_file_map": attr.string(),
        "mergedusr": attr.bool(),
        "target_name": attr.string(),
        "package_name": attr.string(),
    },
)
