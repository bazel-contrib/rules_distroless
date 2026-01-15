"deb_import"

load(":lockfile.bzl", "lockfile")
load(":pkgconfig.bzl", "pkgconfig")
load(":util.bzl", "util")

# BUILD.bazel template
_DEB_IMPORT_BUILD_TMPL = '''
load("@rules_distroless//apt/private:deb_postfix.bzl", "deb_postfix")
load("@rules_distroless//apt/private:deb_export.bzl", "deb_export")
load("@rules_distroless//apt/private:so_library.bzl", "so_library")
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


deb_export(
    name = "export",
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

_CC_IMPORT_TMPL = """
cc_import(
    name = "{name}",
    hdrs = {hdrs},
    includes = {includes},
    linkopts = {linkopts},
    shared_library = {shared_lib},
    static_library = {static_lib},
)
"""

_CC_LIBRARY_TMPL = """
cc_library(
    name = "{name}_wodeps",
    hdrs = {hdrs},
    deps = {direct_deps},
    linkopts = {linkopts},
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    strip_include_prefix = {strip_include_prefix},
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
            print("BL: _discover_contents::resolved_symlink(line={}, sl={})".format(line, resolved_symlink))
            symlinks[line] = resolved_symlink

    # Resolve symlinks:
    unresolved_symlinks = {} | symlinks

    print("BL: _discover_contents::depends_file_map({})".format(depends_file_map))

    # TODO: this is highly inefficient, change the filemapping to be
    # file -> package instead of package -> files
    for dep in depends_on:
        (suite, name, arch, _) = lockfile.parse_package_key(dep)
        filemap = depends_file_map.get(name, []) or []
        print("BL: _discover_contents::for_dep(dep={}, filemap={})".format(name, filemap))
        for file in filemap:
            if len(unresolved_symlinks) == 0:
                break
            for (symlink, symlink_target) in unresolved_symlinks.items():
                print("BL: _discover_contents::depends_on::symlink(symlink={}, symlink_target={})".format(symlink, symlink_target))
                if file == symlink_target:
                    unresolved_symlinks.pop(symlink)
                    symlinks[symlink] = "@%s//:%s" % (util.sanitize(dep), file)
    

    # Resolve self symlinks
    self_symlinks = {}
    for file in so_files + h_files + hpp_files + a_files + hpp_files_woext:
        for (symlink, symlink_target) in unresolved_symlinks.items():
            if file == symlink_target:
                self_symlinks[symlink] = symlinks.pop(symlink)
                unresolved_symlinks.pop(symlink)
                if len(unresolved_symlinks) == 0:
                    break

    print("BL: _discover_contents::depends_on::after(\nsymlinks={}\nself_symlinks={}\nunresolved_symlinks={}\n)".format(symlinks, self_symlinks, unresolved_symlinks))

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

    pkgconfigs = []
    if len(pc_files):
        # TODO: use rctx.extract instead.
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + pc for pc in pc_files],
        )
        for pc in pc_files:
            if rctx.path(pc).exists:
                pkgconfigs.append(pc)

    build_file_content = """
so_library(
    name = "_so_libs",
    dynamic_libs = {}
)
""".format(so_files)

    rpaths = {}
    for so in so_files + a_files:
        rpath = so[:so.rfind("/")]
        rpaths[rpath] = None

    # Package has a pkgconfig, use that as the source of truth.
    if len(pkgconfigs):
        link_paths = []
        includes = []

        static_lib = None
        shared_lib = None

        import_targets = []

        for pc_file in pkgconfigs:
            pkgc = pkgconfig(rctx, pc_file)
            includes += pkgc.includes
            link_paths += pkgc.link_paths

            if not pkgc.libname or pkgc.libname + "_import" in import_targets:
                continue

            subtarget = pkgc.libname + "_import"
            import_targets.append(subtarget)

            # Look for a static archive
            # for ar in a_files:
            #     if ar.endswith(pkgc.libname + ".a"):
            #         static_lib = '":%s"' % ar
            #         break

            # Look for a dynamic library
            IGNORE = ["libfl"]
            for so_lib in so_files:
                if pkgc.libname and pkgc.libname not in IGNORE and so_lib.endswith(pkgc.libname + ".so"):
                    shared_lib = '":%s"' % so_lib
                    break

            build_file_content += _CC_IMPORT_TMPL.format(
                name = subtarget,
                shared_lib = shared_lib,
                static_lib = static_lib,
                hdrs = [],
                includes = {
                    "external/.." + include: True
                    for include in includes + ["/usr/include", "/usr/include/x86_64-linux-gnu"]
                }.keys(),
                linkopts = pkgc.linkopts,
            )

        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + o_files,
            linkopts = {
                opt: True
                for opt in [
                    # # Needed for cc_test binaries to locate its dependencies.
                    # "-Wl,-rpath=../{}/{}".format(rctx.attr.name, rpath)
                    # for rp in rpaths
                ] + [
                    # Needed for cc_test binaries to locate its dependencies as a build tool
                    # "-Wl,-rpath=./external/{}/{}".format(rctx.attr.name, rpath)
                    # for rp in rpaths
                ] + [
                    "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, lp)
                    for lp in link_paths
                ] + [
                    "-Wl,-rpath=/" + rp
                    for rp in rpaths
                ]
            }.keys(),
            direct_deps = import_targets + [":_so_libs"],
            deps = deps,
            strip_include_prefix = None,
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
        extra_linkopts = []
        if target_name == "libbsd0":
            extra_linkopts = [
                "-Wl,--remap-inputs=/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7=$(BINDIR)/external/{}/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7".format(rctx.attr.name),
            ]
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            deps = deps,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + o_files,
            linkopts = [
                # Required for linker to find .so libraries
                "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, rp)
                for rp in rpaths
            ] + [
                # # Required for bazel test binary to find its dependencies.
                # "-Wl,-rpath=../{}/{}".format(rctx.attr.name, rp)
                # for rp in rpaths
            ] + [
                # Required for ld to validate rpath entries
                "-Wl,-rpath-link=$(BINDIR)/external/{}/{}".format(rctx.attr.name, rp)
                for rp in rpaths
            ] + [
                # Required for containers to find the dependencies at runtime.
                "-Wl,-rpath=/" + rp
                for rp in rpaths
            ] + extra_linkopts,
            strip_include_prefix = '"usr/include"',
            direct_deps = [":_so_libs"],
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

    print("BL: symlinks for {} = {}".format(rctx.attr.target_name, symlinks))

    foreign_symlinks = {}
    for (i, symlink) in enumerate(symlinks.values()):
      if symlink not in foreign_symlinks:
        foreign_symlinks[symlink] = []
      foreign_symlinks[symlink].append(i)

    foreign_symlinks = {
      symlink: json.encode(indices)
      for (symlink, indices) in foreign_symlinks.items()
    }

    rctx.file("BUILD.bazel", _DEB_IMPORT_BUILD_TMPL.format(
        mergedusr = rctx.attr.mergedusr,
        depends_on = ["@" + util.sanitize(dep_key) + "//:data" for dep_key in rctx.attr.depends_on],
        target_name = rctx.attr.target_name,
        cc_import_targets = cc_import_targets,
        outs = outs,
        foreign_symlinks = foreign_symlinks,
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
